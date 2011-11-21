
/*
 * Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
 *
 * This file is part of ecoinpool.
 *
 * ecoinpool is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * ecoinpool is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "erl_nif.h"
#include <stdint.h>
#include <string.h>

/* Header files are for beginners. */
extern void BlockHash_1(unsigned char *p512bytes, unsigned char *final_hash);
extern void DoubleSha256(const unsigned char* in, size_t size, unsigned char* out);
extern void TreeDoubleSha256(const unsigned char* in, unsigned char* out);
extern void MidstateSha256(const unsigned char* in, unsigned char* out);

static void reverse32(unsigned char *dst, const unsigned char *src)
{
    int i;
    if (dst == src) {
        for (i = 0; i < 16; ++i) {
            char v = dst[i];
            dst[i] = dst[31-i];
            dst[31-i] = v;
        }
    }
    else {
        for (i = 0; i < 32; ++i)
            dst[31-i] = src[i];
    }
}

static ERL_NIF_TERM dsha256_hash_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char *final_hash = enif_make_new_binary(env, 32, &ret);
    DoubleSha256(bin.data, bin.size, final_hash);
    reverse32(final_hash, final_hash);
    
    return ret;
}

static ERL_NIF_TERM tree_pair_dsha256_hash_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin1, bin2;
    if (!enif_inspect_binary(env, argv[0], &bin1) || bin1.size != 32 || !enif_inspect_binary(env, argv[1], &bin2) || bin2.size != 32)
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char in[64];
    unsigned char *final_hash = enif_make_new_binary(env, 32, &ret);
    reverse32(&in[0], bin1.data);
    reverse32(&in[32], bin2.data);
    TreeDoubleSha256(in, final_hash);
    reverse32(final_hash, final_hash);
    
    return ret;
}

static ERL_NIF_TERM sha256_midstate_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) || bin.size < 64)
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char *midstate = enif_make_new_binary(env, 32, &ret);
    MidstateSha256(bin.data, midstate);
    
    return ret;
}

static ERL_NIF_TERM rs_hash_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) || bin.size != 128)
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char p512bytes[512];
    memcpy(&p512bytes, bin.data, 128);
    unsigned char *final_hash = enif_make_new_binary(env, 32, &ret);
    BlockHash_1(p512bytes, final_hash);
    reverse32(final_hash, final_hash);
    
    return ret;
}

static ErlNifFunc nif_funcs[] = {
    {"dsha256_hash", 1, dsha256_hash_nif},
    {"tree_pair_dsha256_hash", 2, tree_pair_dsha256_hash_nif},
    {"sha256_midstate", 1, sha256_midstate_nif},
    {"rs_hash", 1, rs_hash_nif}
};

ERL_NIF_INIT(ecoinpool_hash, nif_funcs, NULL, NULL, NULL, NULL)
