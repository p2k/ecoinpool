/* -*- mode: c++; c-basic-offset: 4; indent-tabs-mode: nil; tab-width: 4 -*- */
/* vi: set expandtab shiftwidth=4 tabstop=4: */

/**
 * \file
 * <PRE>
 * MODP_B16 - High performance base16 encoder/decoder
 * http://code.google.com/p/stringencoders/
 *
 * Copyright &copy; 2005, 2006, 2007  Nick Galbreath -- nickg [at] modp [dot] com
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *   Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 *
 *   Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the distribution.
 *
 *   Neither the name of the modp.com nor the names of its
 *   contributors may be used to endorse or promote products derived from
 *   this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * This is the standard "new" BSD license:
 * http://www.opensource.org/licenses/bsd-license.php
 * </PRE>
 */

// This file was modified by p2k

#include <stdint.h>

static const unsigned char gsHexEncodeC1[256] = {
 '0',  '0',  '0',  '0',  '0',  '0',  '0',  '0',  '0',  '0',
 '0',  '0',  '0',  '0',  '0',  '0',  '1',  '1',  '1',  '1',
 '1',  '1',  '1',  '1',  '1',  '1',  '1',  '1',  '1',  '1',
 '1',  '1',  '2',  '2',  '2',  '2',  '2',  '2',  '2',  '2',
 '2',  '2',  '2',  '2',  '2',  '2',  '2',  '2',  '3',  '3',
 '3',  '3',  '3',  '3',  '3',  '3',  '3',  '3',  '3',  '3',
 '3',  '3',  '3',  '3',  '4',  '4',  '4',  '4',  '4',  '4',
 '4',  '4',  '4',  '4',  '4',  '4',  '4',  '4',  '4',  '4',
 '5',  '5',  '5',  '5',  '5',  '5',  '5',  '5',  '5',  '5',
 '5',  '5',  '5',  '5',  '5',  '5',  '6',  '6',  '6',  '6',
 '6',  '6',  '6',  '6',  '6',  '6',  '6',  '6',  '6',  '6',
 '6',  '6',  '7',  '7',  '7',  '7',  '7',  '7',  '7',  '7',
 '7',  '7',  '7',  '7',  '7',  '7',  '7',  '7',  '8',  '8',
 '8',  '8',  '8',  '8',  '8',  '8',  '8',  '8',  '8',  '8',
 '8',  '8',  '8',  '8',  '9',  '9',  '9',  '9',  '9',  '9',
 '9',  '9',  '9',  '9',  '9',  '9',  '9',  '9',  '9',  '9',
 'a',  'a',  'a',  'a',  'a',  'a',  'a',  'a',  'a',  'a',
 'a',  'a',  'a',  'a',  'a',  'a',  'b',  'b',  'b',  'b',
 'b',  'b',  'b',  'b',  'b',  'b',  'b',  'b',  'b',  'b',
 'b',  'b',  'c',  'c',  'c',  'c',  'c',  'c',  'c',  'c',
 'c',  'c',  'c',  'c',  'c',  'c',  'c',  'c',  'd',  'd',
 'd',  'd',  'd',  'd',  'd',  'd',  'd',  'd',  'd',  'd',
 'd',  'd',  'd',  'd',  'e',  'e',  'e',  'e',  'e',  'e',
 'e',  'e',  'e',  'e',  'e',  'e',  'e',  'e',  'e',  'e',
 'f',  'f',  'f',  'f',  'f',  'f',  'f',  'f',  'f',  'f',
 'f',  'f',  'f',  'f',  'f',  'f'
};

static const unsigned char gsHexEncodeC2[256] = {
 '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',
 'a',  'b',  'c',  'd',  'e',  'f',  '0',  '1',  '2',  '3',
 '4',  '5',  '6',  '7',  '8',  '9',  'a',  'b',  'c',  'd',
 'e',  'f',  '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',
 '8',  '9',  'a',  'b',  'c',  'd',  'e',  'f',  '0',  '1',
 '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  'a',  'b',
 'c',  'd',  'e',  'f',  '0',  '1',  '2',  '3',  '4',  '5',
 '6',  '7',  '8',  '9',  'a',  'b',  'c',  'd',  'e',  'f',
 '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',
 'a',  'b',  'c',  'd',  'e',  'f',  '0',  '1',  '2',  '3',
 '4',  '5',  '6',  '7',  '8',  '9',  'a',  'b',  'c',  'd',
 'e',  'f',  '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',
 '8',  '9',  'a',  'b',  'c',  'd',  'e',  'f',  '0',  '1',
 '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  'a',  'b',
 'c',  'd',  'e',  'f',  '0',  '1',  '2',  '3',  '4',  '5',
 '6',  '7',  '8',  '9',  'a',  'b',  'c',  'd',  'e',  'f',
 '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',
 'a',  'b',  'c',  'd',  'e',  'f',  '0',  '1',  '2',  '3',
 '4',  '5',  '6',  '7',  '8',  '9',  'a',  'b',  'c',  'd',
 'e',  'f',  '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',
 '8',  '9',  'a',  'b',  'c',  'd',  'e',  'f',  '0',  '1',
 '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  'a',  'b',
 'c',  'd',  'e',  'f',  '0',  '1',  '2',  '3',  '4',  '5',
 '6',  '7',  '8',  '9',  'a',  'b',  'c',  'd',  'e',  'f',
 '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',
 'a',  'b',  'c',  'd',  'e',  'f'
};

static const uint32_t gsHexDecodeMap[256] = {
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
  0,   1,   2,   3,   4,   5,   6,   7,   8,   9, 256, 256,
256, 256, 256, 256, 256,  10,  11,  12,  13,  14,  15, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256,  10,  11,  12,  13,  14,  15, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256
};

static const uint32_t gsHexDecodeD2[256] = {
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
  0,  16,  32,  48,  64,  80,  96, 112, 128, 144, 256, 256,
256, 256, 256, 256, 256, 160, 176, 192, 208, 224, 240, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 160, 176, 192, 208, 224, 240, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256,
256, 256, 256, 256
};


int modp_b16_encode(char* dest, const char* str, int len)
{
    int i;
    const int buckets = len >> 2;
    const int leftover = len & 0x03;

    uint8_t* p = (uint8_t*) dest;
    uint8_t t1, t2, t3, t4;
    uint32_t* srcInt = (uint32_t*) str;
    uint32_t x = *srcInt++;
    for (i = 0; i < buckets; ++i) {
        t4 = (uint8_t) (x >> 24);
        t3 = (uint8_t) (x >> 16);
        t2 = (uint8_t) (x >> 8);
        t1 = (uint8_t) x;
        *p++ = gsHexEncodeC1[t1];
        *p++ = gsHexEncodeC2[t1];
        *p++ = gsHexEncodeC1[t2];
        *p++ = gsHexEncodeC2[t2];
        *p++ = gsHexEncodeC1[t3];
        *p++ = gsHexEncodeC2[t3];
        *p++ = gsHexEncodeC1[t4];
        *p++ = gsHexEncodeC2[t4];
        x = *srcInt++;
    }

    switch (leftover) {
    case 0:
        break;
    case 1:
        t1 = (uint8_t) x;
        *p++ = gsHexEncodeC1[t1];
        *p++ = gsHexEncodeC2[t1];
        break;
    case 2:
        t2 = (uint8_t) (x >>8);
        t1 = (uint8_t) x;
        *p++ = gsHexEncodeC1[t1];
        *p++ = gsHexEncodeC2[t1];
        *p++ = gsHexEncodeC1[t2];
        *p++ = gsHexEncodeC2[t2];
        break;
    default: /* case 3 */
        t3 = (uint8_t) (x >> 16);
        t2 = (uint8_t) (x >>8);
        t1 = (uint8_t) x;
        *p++ = gsHexEncodeC1[t1];
        *p++ = gsHexEncodeC2[t1];
        *p++ = gsHexEncodeC1[t2];
        *p++ = gsHexEncodeC2[t2];
        *p++ = gsHexEncodeC1[t3];
        *p++ = gsHexEncodeC2[t3];
    }
    return  (int)(p - (uint8_t*) dest);
}

int modp_b16_decode(char* dest, const char* str, int len)
{
    int i;

    uint32_t val1, val2;
    uint8_t* p = (uint8_t*) dest;
    uint8_t* s = (uint8_t*) str;

    const int buckets = len >> 2;
    const int leftover = len & 0x03;
    if (leftover & 0x01)
        return -1;
    
    uint8_t t0,t1,t2,t3;
    for (i = 0; i < buckets; ++i) {
        t0 = *s++; t1= *s++; t2 = *s++; t3 = *s++;
        val1 = gsHexDecodeD2[t0] | gsHexDecodeMap[t1];
        val2 = gsHexDecodeD2[t2] | gsHexDecodeMap[t3];
        if (val1 > 0xff || val2 > 0xff) return -1;
        *p++ = (uint8_t) val1;
        *p++ = (uint8_t) val2;
    }

    if (leftover == 2) {
        val1 = gsHexDecodeD2[s[0]] | gsHexDecodeMap[s[1]];
        if (val1 > 0xff) return -1;
        *p++ = (uint8_t) val1;
    }

    return (int)(p - (uint8_t*)dest);
}
