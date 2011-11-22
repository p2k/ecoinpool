
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

extern int modp_b16_encode(unsigned char* dest, unsigned const char* str, int len);
extern int modp_b16_decode(unsigned char* dest, unsigned const char* src, int len);

static ERL_NIF_TERM bin_to_hexbin_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char *dest = enif_make_new_binary(env, bin.size * 2, &ret);
    modp_b16_encode(dest, bin.data, bin.size);
    
    return ret;
}

static ERL_NIF_TERM hexbin_to_bin_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) || bin.size % 2)
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char *dest = enif_make_new_binary(env, bin.size / 2, &ret);
    modp_b16_decode(dest, bin.data, bin.size);
    
    return ret;
}

static ErlNifFunc nif_funcs[] = {
    {"bin_to_hexbin", 1, bin_to_hexbin_nif},
    {"hexbin_to_bin", 1, hexbin_to_bin_nif}
};

ERL_NIF_INIT(ecoinpool_util, nif_funcs, NULL, NULL, NULL, NULL)
