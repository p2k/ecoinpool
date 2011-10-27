
#include "erl_nif.h"
#include <stdint.h>
#include <string.h>

/* Header files are for beginners. */
extern void BlockHash_1(unsigned char *p512bytes, unsigned char *final_hash);

static ERL_NIF_TERM block_hash_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) || bin.size != 128)
        return enif_make_badarg(env);
    
    ERL_NIF_TERM ret;
    unsigned char p512bytes[512];
    memcpy(&p512bytes, bin.data, 128);
    unsigned char *final_hash = enif_make_new_binary(env, 32, &ret);
    BlockHash_1(p512bytes, final_hash);
    
    return ret;
}

static ErlNifFunc nif_funcs[] = {
    {"block_hash", 1, block_hash_nif}
};

ERL_NIF_INIT(rs_hash, nif_funcs, NULL, NULL, NULL, NULL)
