
/*
  This file, in companion with rs_hash_data.bin, circumvents the need of
  initializing the RSHash algorithm.
*/

	.section .rodata
	.globl BlockHash_1_MemoryPAD8

BlockHash_1_MemoryPAD8:
	.incbin "c_src/rs_hash_data.bin"
