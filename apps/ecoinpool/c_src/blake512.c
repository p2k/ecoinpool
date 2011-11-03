
/* This code was taken from the official BLAKE-512 site, modified by RealSolid
   and later slightly refurbished by me. */

#include <string.h>
#include <stdio.h>
#include <stdint.h>

#define U8TO32(p) \
  (((uint32_t)((p)[0]) << 24) | ((uint32_t)((p)[1]) << 16) | \
   ((uint32_t)((p)[2]) <<  8) | ((uint32_t)((p)[3])      ))
#define U8TO64(p) \
  (((uint64_t)U8TO32(p) << 32) | (uint64_t)U8TO32((p) + 4))
#define U32TO8(p, v) \
    (p)[0] = (uint8_t)((v) >> 24); (p)[1] = (uint8_t)((v) >> 16); \
    (p)[2] = (uint8_t)((v) >>  8); (p)[3] = (uint8_t)((v)      );
#define U64TO8(p, v) \
    U32TO8((p),     (uint32_t)((v) >> 32));	\
    U32TO8((p) + 4, (uint32_t)((v)      ));

typedef struct {
  uint64_t h[8];
  uint8_t buf[128];
} state;

const uint8_t sigma[16][16] = 
{
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
  {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
  {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
  { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
  { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
  { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 },
  {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 },
  {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 },
  { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 },
  {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13 ,0 },
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
  {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
  {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
  { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
  { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
  { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 }
};

const uint64_t cst[16] = 
{
  0x243F6A8885A308D3ULL,0x13198A2E03707344ULL,0xA4093822299F31D0ULL,0x082EFA98EC4E6C89ULL,
  0x452821E638D01377ULL,0xBE5466CF34E90C6CULL,0xC0AC29B7C97C50DDULL,0x3F84D5B5B5470917ULL,
  0x9216D5D98979FB1BULL,0xD1310BA698DFB5ACULL,0x2FFD72DBD01ADFB7ULL,0xB8E1AFED6A267E96ULL,
  0xBA7C9045F12C7F99ULL,0x24A19947B3916CF7ULL,0x0801F2E2858EFC16ULL,0x636920D871574E69ULL
};

#define ROT(x,n) (((x)<<(64-n))|( (x)>>(n)))
#define G(m,a,b,c,d,e)					\
  v[a] += (m[sigma[i][e]] ^ cst[sigma[i][e+1]]) + v[b];	\
  v[d] = ROT( v[d] ^ v[a],32);				\
  v[c] += v[d];						\
  v[b] = ROT( v[b] ^ v[c],25);				\
  v[a] += (m[sigma[i][e+1]] ^ cst[sigma[i][e]])+v[b];	\
  v[d] = ROT( v[d] ^ v[a],16);				\
  v[c] += v[d];						\
  v[b] = ROT( v[b] ^ v[c],11);				

void blake512_hash(uint8_t *out, const uint8_t *in)
{
  state S;
  S.h[0]=0x6A09E667F3BCC908ULL;
  S.h[1]=0xBB67AE8584CAA73BULL;
  S.h[2]=0x3C6EF372FE94F82BULL;
  S.h[3]=0xA54FF53A5F1D36F1ULL;
  S.h[4]=0x510E527FADE682D1ULL;
  S.h[5]=0x9B05688C2B3E6C1FULL;
  S.h[6]=0x1F83D9ABFB41BD6BULL;
  S.h[7]=0x5BE0CD19137E2179ULL;

  uint64_t v[16], m[16], i;
  for(i=0; i<16;++i)  m[i] = U8TO64(in + i*8);
  for(i=0; i< 8;++i)  v[i] = S.h[i];
  v[ 8] = 0x243F6A8885A308D3ULL;
  v[ 9] = 0x13198A2E03707344ULL;
  v[10] = 0xA4093822299F31D0ULL;
  v[11] = 0x082EFA98EC4E6C89ULL;
  v[12] = 0x452821E638D01777ULL;
  v[13] = 0xBE5466CF34E9086CULL;
  v[14] = 0xC0AC29B7C97C50DDULL;
  v[15] = 0x3F84D5B5B5470917ULL;

  for(i=0; i<16; ++i) 
  {
    G( m, 0, 4, 8,12, 0);
    G( m, 1, 5, 9,13, 2);
    G( m, 2, 6,10,14, 4);
    G( m, 3, 7,11,15, 6);
    G( m, 3, 4, 9,14,14);   
    G( m, 2, 7, 8,13,12);
    G( m, 0, 5,10,15, 8);
    G( m, 1, 6,11,12,10);
  } 

  for(i=0; i<16;++i)  S.h[i%8] ^= v[i]; 

  const uint64_t m2[16] = {1ULL << 63, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0x400};
  for(i=0; i< 8;++i)  v[i] = S.h[i];
  v[ 8] = 0x243F6A8885A308D3ULL;
  v[ 9] = 0x13198A2E03707344ULL;
  v[10] = 0xA4093822299F31D0ULL;
  v[11] = 0x082EFA98EC4E6C89ULL;
  v[12] =  0x452821E638D01377ULL;
  v[13] =  0xBE5466CF34E90C6CULL;
  v[14] =  0xC0AC29B7C97C50DDULL;
  v[15] =  0x3F84D5B5B5470917ULL;

  for(i=0; i<16; ++i) 
  {
    G( m2, 0, 4, 8,12, 0);
    G( m2, 1, 5, 9,13, 2);
    G( m2, 2, 6,10,14, 4);
    G( m2, 3, 7,11,15, 6);
    G( m2, 3, 4, 9,14,14);   
    G( m2, 2, 7, 8,13,12);
    G( m2, 0, 5,10,15, 8);
    G( m2, 1, 6,11,12,10);
  } 

  for(i=0; i<16;++i)  S.h[i%8] ^= v[i];

  U64TO8( out + 0, S.h[0]);
  U64TO8( out + 8, S.h[1]);
  U64TO8( out +16, S.h[2]);
  U64TO8( out +24, S.h[3]);
  U64TO8( out +32, S.h[4]);
  U64TO8( out +40, S.h[5]);
  U64TO8( out +48, S.h[6]);
  U64TO8( out +56, S.h[7]);
}
