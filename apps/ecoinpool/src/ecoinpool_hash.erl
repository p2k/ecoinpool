
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ecoinpool_hash).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([init/0, dsha256_hash/1, tree_pair_dsha256_hash/2, sha256_midstate/1, rs_hash/1, scrypt_hash/1]).

-export([tree_dsha256_hash/1, tree_level_dsha256_hash/1, first_tree_branches_dsha256_hash/1, fold_tree_branches_dsha256_hash/2]).

-on_load(module_init/0).

module_init() ->
    SoName = case code:priv_dir(ecoinpool) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", "priv"])) of
                true ->
                    filename:join(["..", "priv", atom_to_list(?MODULE)]);
                false ->
                    filename:join(["priv", atom_to_list(?MODULE)])
            end;
        Dir ->
            filename:join(Dir, atom_to_list(?MODULE))
    end,
    ok = erlang:load_nif(SoName, 0).

init() ->
    ok.

dsha256_hash(_) ->
    erlang:nif_error(nif_library_not_loaded).

tree_pair_dsha256_hash(_, _) ->
    erlang:nif_error(nif_library_not_loaded).

sha256_midstate(_) ->
    erlang:nif_error(nif_library_not_loaded).

rs_hash(_) ->
    erlang:nif_error(nif_library_not_loaded).

scrypt_hash(_) ->
    erlang:nif_error(nif_library_not_loaded).

tree_dsha256_hash([Hash]) ->
    Hash;
tree_dsha256_hash(Hashlist) ->
    r_tree_dsha256(Hashlist, fullsize(length(Hashlist), 2)).

tree_level_dsha256_hash([Hash]) ->
    [Hash];
tree_level_dsha256_hash(Level) ->
    tree_level_dsha256_hash(Level, []).

tree_level_dsha256_hash([], Acc) ->
    Acc;
tree_level_dsha256_hash([H1,H2,H3], Acc) ->
    Acc ++ [tree_pair_dsha256_hash(H1, H2), tree_pair_dsha256_hash(H3, H3)];
tree_level_dsha256_hash([H1,H2|T], Acc) ->
    tree_level_dsha256_hash(T, Acc ++ [tree_pair_dsha256_hash(H1, H2)]).

-spec first_tree_branches_dsha256_hash(Hashlist :: [binary()]) -> [binary()].
first_tree_branches_dsha256_hash([]) ->
    [];
first_tree_branches_dsha256_hash([Hash]) ->
    [Hash];
first_tree_branches_dsha256_hash(Hashlist) ->
    l_tree_dsha256([<<"dummy">>|Hashlist], fullsize(length(Hashlist)+1, 2)).

-spec fold_tree_branches_dsha256_hash(TopHash :: binary(), Hashlist :: [binary()]) -> binary().
fold_tree_branches_dsha256_hash(TopHash, []) ->
    TopHash;
fold_tree_branches_dsha256_hash(TopHash, Hashlist) ->
    lists:foldl(fun (Hash, Acc) -> tree_pair_dsha256_hash(Acc, Hash) end, TopHash, Hashlist).

fullsize(N, V) ->
    if
        N =< V -> V;
        true -> fullsize(N, V*2)
    end.

-spec l_tree_dsha256(Hashlist :: [binary()], Size :: integer()) -> [binary()].
l_tree_dsha256([_, Hash], 2) ->
    [Hash];
l_tree_dsha256(Hashlist, Size) ->
    HalfSize = Size div 2,
    {L, R} = lists:split(HalfSize, Hashlist),
    l_tree_dsha256(L, HalfSize) ++ [r_tree_dsha256(R, HalfSize)].

r_tree_dsha256([H], 1) ->
    H;
r_tree_dsha256([H1,H2], 2) ->
    tree_pair_dsha256_hash(H1, H2);
r_tree_dsha256(Hashlist, Size) ->
    HalfSize = Size div 2,
    if
        length(Hashlist) > HalfSize ->
            {L, R} = lists:split(HalfSize, Hashlist),
            tree_pair_dsha256_hash(r_tree_dsha256(L, HalfSize), r_tree_dsha256(R, HalfSize));
        true ->
            LResult = r_tree_dsha256(Hashlist, HalfSize),
            tree_pair_dsha256_hash(LResult, LResult)
    end.

-ifdef(TEST).

btc_sample_header() ->
    base64:decode(<<"AQAAAGpJl3mr0KHNIp5GxjMf1fuqR1/qIRK3OIAGAAAAAAAARyDUB5doFsGHiCruAnPtGoxaosJyISVkCbtLbEzHA/l2JMpOmhEOGkFECaA=">>).

sha256_midstate_test() ->
    ?assertEqual(base64:decode(<<"GMtM3JT43UT02aEl8Xgf636xxQ9rOCso6HBfhUuwlzU=">>), sha256_midstate(btc_sample_header())).

dsha256_hash_test() ->
    ?assertEqual(base64:decode(<<"AAAAAAAAAuPFkwailUxBO6pxrRh9Z7v/pxJh6LLeoc8=">>), dsha256_hash(btc_sample_header())).

rs_hash_test() ->
    ?assertEqual(base64:decode(<<"AAAAAA/q/9gMdBn4bwSEjvPhseM26WEQ9apzJDT+5/o=">>), rs_hash(sc_coindaemon:sample_header())).

scrypt_test() ->
    ?assertEqual(base64:decode(<<"AAAAARDINXlmV230bzuALKiX3retGLEvHCTs/2OG69k=">>), scrypt_hash(scrypt_coindaemon:sample_header())).

-endif.
