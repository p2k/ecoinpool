
/* This file was modified for eye-pleasure. Original code by RealSolid. */

#include <stdint.h>
#include <string.h>

/* Header files, who needs them? */
extern void blake512_hash(uint8_t *out, const uint8_t *in);
extern void sha256(const unsigned char *in, size_t size, unsigned char *out);

extern const uint8_t BlockHash_1_MemoryPAD8[];

#define BLOCKHASH_1_PADSIZE 0x400000
#define PAD_MASK 0x3fffff

void BlockHash_1(uint8_t *p512bytes, uint8_t *final_hash)
{
    //0->127   is the block header      (128)
    //128->191 is blake(blockheader)    (64)
    //192->511 is scratch work area     (320)

    uint8_t *work1 = p512bytes;
    uint8_t *work2 = work1+128;
    uint8_t *work3 = work1+192;

    blake512_hash(work2,work1);

    //setup the 320 scratch with some base values
    work3[0] = work2[15];
    int x;
    for (x = 1; x < 320; x++) {
        work3[x-1] ^= work2[x & 63];
        if(work3[x-1] < 0x80)
	    work3[x] = work2[(x+work3[x-1]) & 63];
        else
	    work3[x] = work1[(x+work3[x-1]) & 127];
    }
    
    #define READ_PAD8(offset) BlockHash_1_MemoryPAD8[(offset)&PAD_MASK]
    #define READ_PAD32(offset) (*((uint32_t*)&BlockHash_1_MemoryPAD8[(offset)&PAD_MASK]))

    uint64_t qCount = *((uint64_t*)&work3[310]);
    int nExtra = READ_PAD8(qCount+work3[300])>>3;
    for (x = 1; x < 512+nExtra; x++) {
        qCount += READ_PAD32( qCount );
        if (qCount & 0x87878700)
	    work3[qCount % 320]++;
	
        qCount -= READ_PAD8( qCount+work3[qCount % 160] );
        if (qCount & 0x80000000)
	    qCount += READ_PAD8( qCount & 0x8080FFFF );
        else
	    qCount += READ_PAD32( qCount & 0x7F60FAFB );
	
        qCount += READ_PAD32( qCount+work3[qCount % 160] );
        if(qCount & 0xF0000000)
	    work3[qCount % 320]++;
	
        qCount += READ_PAD32( *((uint32_t*)&work3[qCount & 0xFF]) );
	work3[x % 320] = work2[x & 63]^((uint8_t)(qCount));

        qCount += READ_PAD32( (qCount>>32)+work3[x % 200] );
        *((uint32_t*)&work3[qCount % 316]) ^= (qCount>>24) & 0xFFFFFFFF;
        if ((qCount & 0x07) == 0x03)
	    x++;
	
        qCount -= READ_PAD8( (x*x) );
        if((qCount & 0x07) == 0x01)
	    x++;
    }

    sha256(work1, 512, final_hash);
}
