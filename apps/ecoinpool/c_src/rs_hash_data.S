
/*
  This file, in companion with rs_hash_data.bin, circumvents the need of
  initializing the RSHash algorithm.
*/

#ifdef __MACH__
	.section __TEXT,__const
	.globl _BlockHash_1_MemoryPAD8

_BlockHash_1_MemoryPAD8:
#else
	.section .rodata
	.globl BlockHash_1_MemoryPAD8

BlockHash_1_MemoryPAD8:
#endif
	.incbin "c_src/rs_hash_data.bin"
