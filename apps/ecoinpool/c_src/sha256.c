
/* This code was stolen somewhere by RealSolid then modified by mtrlt and later refurbished and extended by me. */

#include <string.h>
#include <stdio.h>
#include <stdint.h>

const uint32_t K[64] = 
{ 
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

uint32_t rotl(uint32_t x, uint32_t y)
{
    return (x<<y)|(x>>(32-y));
}

uint32_t EndianSwap(uint32_t n)
{
    return ((n&0xFF)<<24) | ((n&0xFF00)<<8) | ((n&0xFF0000)>>8) | ((n&0xFF000000)>>24);
}

void Write64BigEndian(uint8_t *to, uint64_t v)
{
    uint8_t *from = (uint8_t *)&v;
    to[0] = from[7];
    to[1] = from[6];
    to[2] = from[5];
    to[3] = from[4];
    to[4] = from[3];
    to[5] = from[2];
    to[6] = from[1];
    to[7] = from[0];
}

#define Ch(x, y, z) (z ^ (x & (y ^ z)))
#define Ma(x, y, z) ((y & z) | (x & (y | z)))

#define Tr(x,a,b,c) (rotl(x,a)^rotl(x,b)^rotl(x,c))

#define R(x) (work[x] = (rotl(work[x-2],15)^rotl(work[x-2],13)^((work[x-2])>>10)) + work[x-7] + (rotl(work[x-15],25)^rotl(work[x-15],14)^((work[x-15])>>3)) + work[x-16])
#define sharound(a,b,c,d,e,f,g,h,x,K) h+=Tr(e,7,21,26)+Ch(e,f,g)+K+x; d+=h; h+=Tr(a,10,19,30)+Ma(a,b,c);

void Sha256_initialize(uint32_t* s)
{
    s[0]=0x6a09e667;
    s[1]=0xbb67ae85;
    s[2]=0x3c6ef372;
    s[3]=0xa54ff53a;
    s[4]=0x510e527f;
    s[5]=0x9b05688c;
    s[6]=0x1f83d9ab;
    s[7]=0x5be0cd19;
}

void Sha256_round(uint32_t* s, const unsigned char* data)
{
    uint32_t work[64];
    uint32_t i;

    uint32_t* udata = (uint32_t*)data;
    for (i=0; i<16; ++i)
        work[i] = EndianSwap(udata[i]);

    uint32_t A = s[0];
    uint32_t B = s[1];
    uint32_t C = s[2];
    uint32_t D = s[3];
    uint32_t E = s[4];
    uint32_t F = s[5];
    uint32_t G = s[6];
    uint32_t H = s[7];
    sharound(A,B,C,D,E,F,G,H,work[0],K[0]);
    sharound(H,A,B,C,D,E,F,G,work[1],K[1]);
    sharound(G,H,A,B,C,D,E,F,work[2],K[2]);
    sharound(F,G,H,A,B,C,D,E,work[3],K[3]);
    sharound(E,F,G,H,A,B,C,D,work[4],K[4]);
    sharound(D,E,F,G,H,A,B,C,work[5],K[5]);
    sharound(C,D,E,F,G,H,A,B,work[6],K[6]);
    sharound(B,C,D,E,F,G,H,A,work[7],K[7]);
    sharound(A,B,C,D,E,F,G,H,work[8],K[8]);
    sharound(H,A,B,C,D,E,F,G,work[9],K[9]);
    sharound(G,H,A,B,C,D,E,F,work[10],K[10]);
    sharound(F,G,H,A,B,C,D,E,work[11],K[11]);
    sharound(E,F,G,H,A,B,C,D,work[12],K[12]);
    sharound(D,E,F,G,H,A,B,C,work[13],K[13]);
    sharound(C,D,E,F,G,H,A,B,work[14],K[14]);
    sharound(B,C,D,E,F,G,H,A,work[15],K[15]);
    sharound(A,B,C,D,E,F,G,H,R(16),K[16]);
    sharound(H,A,B,C,D,E,F,G,R(17),K[17]);
    sharound(G,H,A,B,C,D,E,F,R(18),K[18]);
    sharound(F,G,H,A,B,C,D,E,R(19),K[19]);
    sharound(E,F,G,H,A,B,C,D,R(20),K[20]);
    sharound(D,E,F,G,H,A,B,C,R(21),K[21]);
    sharound(C,D,E,F,G,H,A,B,R(22),K[22]);
    sharound(B,C,D,E,F,G,H,A,R(23),K[23]);
    sharound(A,B,C,D,E,F,G,H,R(24),K[24]);
    sharound(H,A,B,C,D,E,F,G,R(25),K[25]);
    sharound(G,H,A,B,C,D,E,F,R(26),K[26]);
    sharound(F,G,H,A,B,C,D,E,R(27),K[27]);
    sharound(E,F,G,H,A,B,C,D,R(28),K[28]);
    sharound(D,E,F,G,H,A,B,C,R(29),K[29]);
    sharound(C,D,E,F,G,H,A,B,R(30),K[30]);
    sharound(B,C,D,E,F,G,H,A,R(31),K[31]);
    sharound(A,B,C,D,E,F,G,H,R(32),K[32]);
    sharound(H,A,B,C,D,E,F,G,R(33),K[33]);
    sharound(G,H,A,B,C,D,E,F,R(34),K[34]);
    sharound(F,G,H,A,B,C,D,E,R(35),K[35]);
    sharound(E,F,G,H,A,B,C,D,R(36),K[36]);
    sharound(D,E,F,G,H,A,B,C,R(37),K[37]);
    sharound(C,D,E,F,G,H,A,B,R(38),K[38]);
    sharound(B,C,D,E,F,G,H,A,R(39),K[39]);
    sharound(A,B,C,D,E,F,G,H,R(40),K[40]);
    sharound(H,A,B,C,D,E,F,G,R(41),K[41]);
    sharound(G,H,A,B,C,D,E,F,R(42),K[42]);
    sharound(F,G,H,A,B,C,D,E,R(43),K[43]);
    sharound(E,F,G,H,A,B,C,D,R(44),K[44]);
    sharound(D,E,F,G,H,A,B,C,R(45),K[45]);
    sharound(C,D,E,F,G,H,A,B,R(46),K[46]);
    sharound(B,C,D,E,F,G,H,A,R(47),K[47]);
    sharound(A,B,C,D,E,F,G,H,R(48),K[48]);
    sharound(H,A,B,C,D,E,F,G,R(49),K[49]);
    sharound(G,H,A,B,C,D,E,F,R(50),K[50]);
    sharound(F,G,H,A,B,C,D,E,R(51),K[51]);
    sharound(E,F,G,H,A,B,C,D,R(52),K[52]);
    sharound(D,E,F,G,H,A,B,C,R(53),K[53]);
    sharound(C,D,E,F,G,H,A,B,R(54),K[54]);
    sharound(B,C,D,E,F,G,H,A,R(55),K[55]);
    sharound(A,B,C,D,E,F,G,H,R(56),K[56]);
    sharound(H,A,B,C,D,E,F,G,R(57),K[57]);
    sharound(G,H,A,B,C,D,E,F,R(58),K[58]);
    sharound(F,G,H,A,B,C,D,E,R(59),K[59]);
    sharound(E,F,G,H,A,B,C,D,R(60),K[60]);
    sharound(D,E,F,G,H,A,B,C,R(61),K[61]);
    sharound(C,D,E,F,G,H,A,B,R(62),K[62]);
    sharound(B,C,D,E,F,G,H,A,R(63),K[63]);

    s[0] += A;
    s[1] += B;
    s[2] += C;
    s[3] += D;
    s[4] += E;
    s[5] += F;
    s[6] += G;
    s[7] += H;
}

void DoubleSha256(const unsigned char* in, size_t size, unsigned char* out)
{
    size_t i;
    uint32_t s[8];
    union {
        uint8_t chars[64];
        uint32_t ints[16];
    } padding;
    
    Sha256_initialize(s);
    
    for (i = size; i >= 64; i -= 64, in += 64)
        Sha256_round(s, in);
    
    if (i > 0) memcpy(&padding.chars[0], &in[0], i);
    padding.chars[i] = 0x80;
    if (i > 55) {
        if (i < 63) memset(&padding.chars[i+1], 0, 63-i);
        Sha256_round(s, &padding.chars[0]);
        padding.chars[0] = 0;
        i = 0;
    }
    if (i < 55) memset(&padding.chars[i+1], 0, 55-i);
    
    Write64BigEndian(&padding.chars[56], size << 3);
    Sha256_round(s, &padding.chars[0]);
    
    padding.ints[0] = EndianSwap(s[0]);
    padding.ints[1] = EndianSwap(s[1]);
    padding.ints[2] = EndianSwap(s[2]);
    padding.ints[3] = EndianSwap(s[3]);
    padding.ints[4] = EndianSwap(s[4]);
    padding.ints[5] = EndianSwap(s[5]);
    padding.ints[6] = EndianSwap(s[6]);
    padding.ints[7] = EndianSwap(s[7]);
    
    padding.chars[32] = 0x80;
    memset(&padding.chars[33], 0, 31);
    padding.chars[62] = 1;
    
    Sha256_initialize(s);
    Sha256_round(s, &padding.chars[0]);
    
    uint32_t* outi = (uint32_t*)out;
    outi[0] = EndianSwap(s[0]);
    outi[1] = EndianSwap(s[1]);
    outi[2] = EndianSwap(s[2]);
    outi[3] = EndianSwap(s[3]);
    outi[4] = EndianSwap(s[4]);
    outi[5] = EndianSwap(s[5]);
    outi[6] = EndianSwap(s[6]);
    outi[7] = EndianSwap(s[7]);
}

// Quickly hashes the concatenation of two other hashes; input must be 64 bytes
void TreeDoubleSha256(const unsigned char* in, unsigned char* out)
{
    union {
        uint8_t chars[64];
        uint32_t ints[16];
    } padding;
    uint32_t s[8];
    
    Sha256_initialize(s);
    Sha256_round(s, in);
    
    padding.chars[0] = 0x80;
    memset(&padding.chars[1], 0, 63);
    padding.chars[62] = 2;
    Sha256_round(s, &padding.chars[0]);
    
    padding.ints[0] = EndianSwap(s[0]);
    padding.ints[1] = EndianSwap(s[1]);
    padding.ints[2] = EndianSwap(s[2]);
    padding.ints[3] = EndianSwap(s[3]);
    padding.ints[4] = EndianSwap(s[4]);
    padding.ints[5] = EndianSwap(s[5]);
    padding.ints[6] = EndianSwap(s[6]);
    padding.ints[7] = EndianSwap(s[7]);
    
    padding.chars[32] = 0x80;
    memset(&padding.chars[33], 0, 31);
    padding.chars[62] = 1;
    
    Sha256_initialize(s);
    Sha256_round(s, &padding.chars[0]);
    
    uint32_t* outi = (uint32_t*)out;
    outi[0] = EndianSwap(s[0]);
    outi[1] = EndianSwap(s[1]);
    outi[2] = EndianSwap(s[2]);
    outi[3] = EndianSwap(s[3]);
    outi[4] = EndianSwap(s[4]);
    outi[5] = EndianSwap(s[5]);
    outi[6] = EndianSwap(s[6]);
    outi[7] = EndianSwap(s[7]);
}

//assumes input is 64 bytes (or longer)
void MidstateSha256(const unsigned char* in, unsigned char* out)
{
    uint32_t *outi = (uint32_t *)out;
    Sha256_initialize(outi);
    Sha256_round(outi, in);
}

uint8_t padding[64] = 
{
    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
};

//assumes input is 512 bytes
void Sha256(unsigned char* in, unsigned char* out)
{
    uint32_t s[8];
    Sha256_initialize(s);
    Sha256_round(s, in);
    Sha256_round(s, in+64);
    Sha256_round(s, in+128);
    Sha256_round(s, in+192);
    Sha256_round(s, in+256);
    Sha256_round(s, in+320);
    Sha256_round(s, in+384);
    Sha256_round(s, in+448);
    Sha256_round(s, padding);

    uint32_t* outi = (uint32_t*)out;
    outi[0] = EndianSwap(s[0]);
    outi[1] = EndianSwap(s[1]);
    outi[2] = EndianSwap(s[2]);
    outi[3] = EndianSwap(s[3]);
    outi[4] = EndianSwap(s[4]);
    outi[5] = EndianSwap(s[5]);
    outi[6] = EndianSwap(s[6]);
    outi[7] = EndianSwap(s[7]);
}
