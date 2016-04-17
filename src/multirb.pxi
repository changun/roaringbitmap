cdef class MultiRoaringBitmap(object):
	"""A sequence of immutable roaring bitmaps.

	Bitmaps are addressed with 32-bit indices.
	Everything is stored in a single contiguous block of memory.

	>>> mrb = MultiRoaringBitmap([
	...    RoaringBitmap({0, 1, 2}),
	...    RoaringBitmap({1, 6, 8}),
	...    RoaringBitmap({1, 7, 2})])
	>>> mrb.intersection(list(range(len(mrb))))
	RoaringBitmap({1})
	>>> mrb[0] | mrb[1]
	RoaringBitmap({0, 1, 2, 6, 8})
	"""
	cdef uint32_t size  # the number of roaring bitmaps
	cdef uint32_t *offsets  # byte offset in ptr for each roaring bitmap
	cdef uint32_t *sizes  # the size in bytes of each roaring bitmap
	cdef uint32_t *ptr  # the data
	cdef object state  # array or mmap which should be kept alive for ptr
	cdef object file

	def __init__(self, list init, filename=None):
		"""
		:param init: a list of set-like objects (e.g., RoaringBitmaps).
		:param filename: if given, result is stored in an mmap'd file.
			File is overwritten if it already exists."""
		cdef ImmutableRoaringBitmap irb
		cdef uint32_t alloc, offset
		cdef int alignment = 32
		cdef char [:] vstate
		if filename is not None:
			self.file = open(filename, 'wb+', buffering=0)

		tmp = [None if a is None else ImmutableRoaringBitmap(a) for a in init]
		self.size = len(tmp)
		alloc = sizeof(uint32_t) + 2 * self.size * sizeof(uint32_t)
		extra = alignment - alloc % alignment
		alloc += extra
		offset = alloc
		for irb in tmp:
			if irb is not None:
				alloc += irb.bufsize

		if filename is not None:
			self.file.truncate(alloc)
		self.state = mmap.mmap(
				-1 if filename is None
				else self.file.fileno(),
				alloc, access=mmap.ACCESS_WRITE)
		vstate = MagicMemoryView(self.state, (alloc, ), b'c')
		self.ptr = <uint32_t *>&vstate[0]

		self.ptr[0] = self.size
		self.offsets = &(self.ptr[1])
		self.sizes = &(self.ptr[1 + self.size])
		for n in range(1 + 2 * self.size,
				1 + 2 * self.size + extra // sizeof(uint32_t)):
			self.ptr[n] = 0
		for n, irb in enumerate(tmp):
			# offset
			self.ptr[1 + n] = offset
			# size
			if irb is None:
				self.ptr[1 + n + self.size] = 0
				continue
			self.ptr[1 + n + self.size] = irb.bufsize
			# copy data
			memcpy(&(vstate[offset]), irb.ptr, irb.bufsize)
			offset += irb.bufsize
		if filename is not None:
			self.state.flush()

	def __dealloc__(self):
		if isinstance(self.state, mmap.mmap):
			self.state.close()
			if self.file is not None:
				self.file.close()

	def __getstate__(self):
		return bytes(self.state)

	def __setstate__(self, state):
		self.state = state
		self.ptr = <uint32_t *><char *>state
		self.size = self.ptr[0]
		self.offsets = &(self.ptr[1])
		self.sizes = &(self.ptr[1 + self.size])

	@classmethod
	def fromfile(cls, filename):
		"""Load a MultiRoaringBitmap from a file using mmap."""
		cdef MultiRoaringBitmap ob
		cdef char [:] vstate
		ob = MultiRoaringBitmap.__new__(MultiRoaringBitmap)
		ob.file = open(filename, 'rb')
		ob.state = mmap.mmap(ob.file.fileno(), 0, access=mmap.ACCESS_READ)
		vstate = MagicMemoryView(ob.state, (len(ob.state), ), b'c')
		ob.ptr = <uint32_t *>&vstate[0]
		ob.size = ob.ptr[0]
		ob.offsets = &(ob.ptr[1])
		ob.sizes = &(ob.ptr[1 + ob.size])
		# rest is data
		return ob

	@classmethod
	def frombuffer(cls, data, int offset):
		cdef MultiRoaringBitmap ob = MultiRoaringBitmap.__new__(
				MultiRoaringBitmap)
		cdef char [:] vstate = MagicMemoryView(data, (len(data), ), b'c')
		ob.ptr = <uint32_t *>&vstate[offset]
		ob.size = ob.ptr[0]
		ob.offsets = &(ob.ptr[1])
		ob.sizes = &(ob.ptr[1 + ob.size])
		# rest is data
		return ob

	def bufsize(self):
		"""Return size in number of bytes."""
		return self.offsets[self.size - 1] + self.sizes[self.size - 1]

	def __len__(self):
		return self.size

	def __getitem__(self, long i):
		"""Return a copy of bitmap `i` as an ``ImmutableRoaringBitmap``,
		or ``None`` if it is empty."""
		cdef ImmutableRoaringBitmap ob1
		if self.sizes[i] == 0:
			return None
		ob1 = ImmutableRoaringBitmap.__new__(ImmutableRoaringBitmap)
		ob1._setptr(&(<char *>self.ptr)[self.offsets[i]], self.sizes[i])
		return ob1

	def getsize(self, long i):
		return self.sizes[i]

	def intersection(self, list indices,
			uint32_t start=0, uint32_t stop=0xffffffffUL):
		"""Compute intersection of given a list of indices of roaring bitmaps
		in this collection.

		:returns: the intersection as a mutable RoaringBitmap.
			Returns ``None`` when an invalid index is encountered or an empty
			result is obtained.
		:param start, stop: if given, only return elements `n`
			s.t. ``start <= n < stop``."""
		cdef ImmutableRoaringBitmap ob1, ob2
		cdef RoaringBitmap result
		cdef char *ptr = <char *>self.ptr
		cdef long i, j, numindices = len(indices)
		if numindices == 0:
			return None
		for i in range(numindices):
			j = indices[i]
			if j > self.size or self.sizes[j] == 0:
				return None
		ob1 = ImmutableRoaringBitmap.__new__(ImmutableRoaringBitmap)
		if numindices == 1:
			i = indices[0]
			ob1._setptr(&(ptr[self.offsets[i]]), self.sizes[i])
			if start or stop < 0xffffffffUL:
				return rb_clamp(ob1, start, stop)
			return ob1
		indices.sort(key=self.getsize)
		ob2 = ImmutableRoaringBitmap.__new__(ImmutableRoaringBitmap)
		# TODO with nogil?:
		i, j = indices[0], indices[1]
		ob1._setptr(&(ptr[self.offsets[i]]), self.sizes[i])
		ob2._setptr(&(ptr[self.offsets[j]]), self.sizes[j])
		if start or stop < 0xffffffffUL:
			result = rb_clamp(ob1, start, stop)
			rb_iand(result, ob2)
		else:
			result = rb_and(ob1, ob2)
		for i in range(2, numindices):
			j = indices[i]
			# swap out contents of ImmutableRoaringBitmap object
			ob1._setptr(&(ptr[self.offsets[j]]), self.sizes[j])
			rb_iand(result, ob1)
			if result.size == 0:
				return None
		return result

	def jaccard_dist(self, array.array indices1, array.array indices2):
		"""Compute the Jaccard distances for pairs of roaring bitmaps
		in this collection given by ``zip(indices1, indices2)``.

		>>> mrb.jaccard_dist(array.array('L', [0, 6, 8]),
		...			array.array('L', [1, 7, 6]))
		array.array('d', [0.3, 0.2, 0.56])

		:param indices1, indices2: arrays of unsigned long integers.
		"""
		cdef ImmutableRoaringBitmap ob1, ob2
		cdef array.array result = array.clone(dblarray, len(indices1), False)
		cdef char *ptr = <char *>self.ptr
		cdef int i, j, n
		ob1 = ImmutableRoaringBitmap.__new__(ImmutableRoaringBitmap)
		ob2 = ImmutableRoaringBitmap.__new__(ImmutableRoaringBitmap)
		for n in range(len(indices1)):
			i, j = indices1.data.as_ulongs[n], indices2.data.as_ulongs[n]
			ob1._setptr(&(ptr[self.offsets[i]]), self.sizes[i])
			ob2._setptr(&(ptr[self.offsets[j]]), self.sizes[j])
			result.data.as_doubles[n] = (rb_jaccard_dist(ob1, ob2)
					if self.sizes[i] and self.sizes[j] else 1)
		return result
