
/*
  This file, in companion with rs_hash_data.bin, circumvents the need of
  initializing the RSHash algorithm.
*/

	.section __TEXT,__const
	.globl _BlockHash_1_MemoryPAD8

_BlockHash_1_MemoryPAD8:
	.incbin "c_src/rs_hash_data.bin"
