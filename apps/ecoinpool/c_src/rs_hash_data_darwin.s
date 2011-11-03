
/*
  This file, in companion with rs_hash_data.bin, prevents us from witnessing
  RealSolid's embarrassing 15 minutes of fame. Thank you RealSolid, my pleasure.
*/

	.section __TEXT,__const
	.globl _BlockHash_1_MemoryPAD8

_BlockHash_1_MemoryPAD8:
	.incbin "c_src/rs_hash_data.bin"
