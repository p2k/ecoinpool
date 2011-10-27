
-module(rs_hash).

-export([block_hash/1, block_hash_init/0]).

-on_load(init/0).

init() ->
    SoName = case code:priv_dir(?MODULE) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", priv])) of
                true ->
                    filename:join(["..", priv, ?MODULE]);
                false ->
                    filename:join([priv, ?MODULE])
            end;
        Dir ->
            filename:join(Dir, ?MODULE)
    end,
    ok = erlang:load_nif(SoName, 0).

block_hash_init() ->
    ok.

block_hash(_X) ->
    exit(nif_library_not_loaded).
