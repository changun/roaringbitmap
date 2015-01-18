from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t
from libc.string cimport memcpy

cdef extern from "macros.h":
	int BITSIZE
	int BITSLOT(int b)
	uint64_t BITMASK(int b)
	uint64_t TESTBIT(uint64_t a[], int b)
	void CLEARBIT(uint64_t a[], int b)
	void SETBIT(uint64_t a[], int b)


cdef extern from "bitcount.h":
	unsigned int bit_clz(uint64_t)
	unsigned int bit_ctz(uint64_t)
	unsigned int bit_popcount(uint64_t)


# cdef inline functions defined here:
# ===================================
# cdef inline int abitcount(uint64_t *vec, int slots)
# cdef inline int anextset(uint64_t *vec, uint32_t pos, int slots)
# cdef inline int anextunset(uint64_t *vec, uint32_t pos, int slots)
# cdef inline bint bitsubset(uint64_t *vec1, uint64_t *vec2, int slots)
# cdef inline void bitsetunioninplace(uint64_t *dest,
# 		uint64_t *src, int slots)
# cdef inline void bitsetintersectinplace(uint64_t *dest,
# 		uint64_t *src, int slots)
# cdef inline void bitsetunion(uint64_t *dest, uint64_t *src1,
# 		uint64_t *src2, int slots)
# cdef inline void bitsetintersect(uint64_t *dest, uint64_t *src1,
# 		uint64_t *src2, int slots)
# cdef inline int iteratesetbits(uint64_t *vec, int slots,
# 		uint64_t *cur, int *idx)
# cdef inline int iterateunsetbits(uint64_t *vec, int slots,
# 		uint64_t *cur, int *idx)
# cdef inline int reviteratesetbits(uint64_t *vec, uint64_t *cur, int *idx)


cdef inline int abitcount(uint64_t *vec, int slots):
	""" Return number of set bits in variable length bitvector """
	cdef int a
	cdef int result = 0
	for a in range(slots):
		result += bit_popcount(vec[a])
	return result


cdef inline int abitlength(uint64_t *vec, int slots):
	"""Return number of bits needed to represent vector.

	(equivalently: index of most significant set bit, plus one)."""
	cdef int a = slots - 1
	while a and not vec[a]:
		a -= 1
	return (a + 1) * sizeof(uint64_t) * 8 - bit_clz(vec[a])


cdef inline int anextset(uint64_t *vec, uint32_t pos, int slots):
	""" Return next set bit starting from pos, -1 if there is none. """
	cdef int a = BITSLOT(pos)
	cdef uint64_t x
	if a >= slots:
		return -1
	x = vec[a] & (~0UL << (pos % BITSIZE))
	while x == 0UL:
		a += 1
		if a == slots:
			return -1
		x = vec[a]
	return a * BITSIZE + bit_ctz(x)


cdef inline int anextunset(uint64_t *vec, uint32_t pos, int slots):
	""" Return next unset bit starting from pos. """
	cdef int a = BITSLOT(pos)
	cdef uint64_t x
	if a >= slots:
		return a * BITSIZE
	x = vec[a] | (BITMASK(pos) - 1)
	while x == ~0UL:
		a += 1
		if a == slots:
			return a * BITSIZE
		x = vec[a]
	return a * BITSIZE + bit_ctz(~x)


cdef inline int iteratesetbits(uint64_t *vec, int slots,
		uint64_t *cur, int *idx):
	"""Iterate over set bits in an array of unsigned long.

	:param slots: number of elements in unsigned long array ``vec``.
	:param cur and idx: pointers to variables to maintain state,
		``idx`` should be initialized to 0,
		and ``cur`` to the first element of
		the bit array ``vec``, i.e., ``cur = vec[idx]``.
	:returns: the index of a set bit, or -1 if there are no more set
		bits. The result of calling a stopped iterator is undefined.

	e.g.::

		int idx = 0
		uint64_t vec[4] = {0, 0, 0, 0b10001}, cur = vec[idx]
		iteratesetbits(vec, 4, &cur, &idx) # returns 0
		iteratesetbits(vec, 4, &cur, &idx) # returns 4
		iteratesetbits(vec, 4, &cur, &idx) # returns -1
	"""
	cdef int tmp
	while not cur[0]:
		idx[0] += 1
		if idx[0] >= slots:
			return -1
		cur[0] = vec[idx[0]]
	tmp = bit_ctz(cur[0])  # index of right-most 1-bit in current slot
	cur[0] ^= 1UL << tmp  # TOGGLEBIT(cur, tmp)
	return idx[0] * BITSIZE + tmp


cdef inline int iterateunsetbits(uint64_t *vec, int slots,
		uint64_t *cur, int *idx):
	"""Like ``iteratesetbits``, but return indices of zero bits.

	:param cur: should be initialized as: ``cur = ~vec[idx]``."""
	cdef int tmp
	while not cur[0]:
		idx[0] += 1
		if idx[0] >= slots:
			return -1
		cur[0] = ~vec[idx[0]]
	tmp = bit_ctz(cur[0])  # index of right-most 0-bit in current slot
	cur[0] ^= 1UL << tmp  # TOGGLEBIT(cur, tmp)
	return idx[0] * BITSIZE + tmp


cdef inline int reviteratesetbits(uint64_t *vec, uint64_t *cur, int *idx):
	"""Iterate in reverse over set bits in an array of unsigned long.

	:param cur and idx: pointers to variables to maintain state,
		``idx`` should be initialized to ``slots - 1``, where slots is the
		number of elements in unsigned long array ``vec``.
		``cur`` should be initialized to the last element of
		the bit array ``vec``, i.e., ``cur = vec[idx]``.
	:returns: the index of a set bit, or -1 if there are no more set
		bits. The result of calling a stopped iterator is undefined.

	e.g.::

		int idx = 3
		uint64_t vec[4] = {0, 0, 0, 0b10001}, cur = vec[idx]
		reviteratesetbits(vec, 4, &cur, &idx) # returns 4
		reviteratesetbits(vec, 4, &cur, &idx) # returns 0
		reviteratesetbits(vec, 4, &cur, &idx) # returns -1
	"""
	cdef int tmp
	while not cur[0]:
		idx[0] -= 1
		if idx[0] < 0:
			return -1
		cur[0] = vec[idx[0]]
	tmp = BITSIZE - bit_clz(cur[0]) - 1  # index of left-most 1-bit in cur
	cur[0] &= ~(1UL << tmp)  # CLEARBIT(cur, tmp)
	return idx[0] * BITSIZE + tmp


cdef inline int bitsetintersectinplace(uint64_t *dest, uint64_t *src,
		int slots):
	"""dest gets the intersection of dest and src.

	Returns number of set bits in result.
	Both operands must have at least `slots' slots."""
	cdef int a
	cdef size_t result = 0
	for a in range(slots):
		dest[a] &= src[a]
		result += bit_popcount(dest[a])
	return result


cdef inline int bitsetunioninplace(uint64_t *dest, uint64_t *src, int slots):
	"""dest gets the union of dest and src.

	Returns number of set bits in result.
	Both operands must have at least ``slots`` slots."""
	cdef int a
	cdef size_t result = 0
	for a in range(slots):
		dest[a] |= src[a]
		result += bit_popcount(dest[a])
	return result


cdef inline int bitsetsubtractinplace(uint64_t *dest, uint64_t *src1,
		int slots):
	"""dest gets dest - src2.

	Returns number of set bits in result.
	Both operands must have at least ``slots`` slots."""
	cdef int a
	cdef size_t result = 0
	for a in range(slots):
		dest[a] &= ~src1[a]
		result += bit_popcount(dest[a])
	return result


cdef inline int bitsetxorinplace(uint64_t *dest, uint64_t *src1,
		int slots):
	"""dest gets dest ^ src2.

	Returns number of set bits in result.
	Both operands must have at least ``slots`` slots."""
	cdef int a
	cdef size_t result = 0
	for a in range(slots):
		dest[a] ^= src1[a]
		result += bit_popcount(dest[a])
	return result


cdef inline void bitsetintersect(uint64_t *dest, uint64_t *src1,
		uint64_t *src2, int slots):
	"""dest gets the intersection of src1 and src2.

	operands must have at least ``slots`` slots."""
	cdef int a
	for a in range(slots):
		dest[a] = src1[a] & src2[a]


cdef inline void bitsetunion(uint64_t *dest, uint64_t *src1, uint64_t *src2,
		int slots):
	"""dest gets the union of src1 and src2.

	operands must have at least ``slots`` slots."""
	cdef int a
	for a in range(slots):
		dest[a] = src1[a] | src2[a]


cdef inline void bitsetsubtract(uint64_t *dest, uint64_t *src1, uint64_t *src2,
		int slots):
	"""dest gets src1 - src2.

	operands must have at least ``slots`` slots."""
	cdef int a
	for a in range(slots):
		dest[a] = src1[a] & ~src2[a]


cdef inline void bitsetxor(uint64_t *dest, uint64_t *src1, uint64_t *src2,
		int slots):
	"""dest gets src1 ^ src2.

	operands must have at least ``slots`` slots."""
	cdef int a
	for a in range(slots):
		dest[a] = src1[a] ^ src2[a]


cdef inline bint bitsubset(uint64_t *vec1, uint64_t *vec2, int slots):
	"""Test whether vec1 is a subset of vec2.

	i.e., all set bits of vec1 should be set in vec2."""
	cdef int a
	for a in range(slots):
		if (vec1[a] & vec2[a]) != vec1[a]:
			return False
	return True

cdef inline int select64(uint64_t w, int i):
	"""Given a 64-bit int w, return the position of the ith 1-bit."""
	cdef uint64_t part1 = w & 0xFFFFFFFF
	cdef int wfirsthalf = bit_popcount(part1)
	if wfirsthalf > i:
		return select32(part1, i)
	else:
		return select32(<uint32_t>(w >> 32), i - wfirsthalf) + 32


cdef inline int select32(uint32_t w, int i):
	"""Given a 32-bit int w, return the position of the ith 1-bit."""
	cdef uint64_t part1 = w & 0xFFFF
	cdef int wfirsthalf = bit_popcount(part1)
	if wfirsthalf > i:
		return select16(part1, i)
	else:
		return select16(w >> 16, i - wfirsthalf) + 16


cdef inline int select16(uint16_t w, int i):
	"""Given a 16-bit int w, return the position of the ith 1-bit."""
	cdef int sumtotal = 0, counter
	for counter in range(16):
		sumtotal += (w >> counter) & 1
		if sumtotal > i:
			return counter
	raise ValueError('cannot locate %dth bit in word with %d bits.' % (
			i, bit_popcount(w)))
