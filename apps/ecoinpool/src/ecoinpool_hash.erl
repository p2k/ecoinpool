
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

-export([init/0, dsha256_hash/1, tree_dsha256_hash/1, tree_level_dsha256_hash/1, tree_pair_dsha256_hash/2, sha256_midstate/1, rs_hash/1]).

-on_load(module_init/0).

module_init() ->
    SoName = case code:priv_dir(ecoinpool) of
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

init() ->
    ok.

dsha256_hash(_) ->
    exit(nif_library_not_loaded).

tree_dsha256_hash([]) ->
    [];
tree_dsha256_hash([Result]) ->
    Result;
tree_dsha256_hash(Level) ->
    tree_dsha256_hash(tree_level_dsha256_hash(Level, [])).

tree_level_dsha256_hash([Result]) ->
    [Result];
tree_level_dsha256_hash(Level) ->
    tree_level_dsha256_hash(Level, []).

tree_level_dsha256_hash([], Acc) ->
    Acc;
tree_level_dsha256_hash([H1,H2,H3], Acc) ->
    Acc ++ [tree_pair_dsha256_hash(H1, H2), tree_pair_dsha256_hash(H3, H3)];
tree_level_dsha256_hash([H1,H2|T], Acc) ->
    tree_level_dsha256_hash(T, Acc ++ [tree_pair_dsha256_hash(H1, H2)]).

tree_pair_dsha256_hash(_, _) ->
    exit(nif_library_not_loaded).

sha256_midstate(_) ->
    exit(nif_library_not_loaded).

rs_hash(_) ->
    exit(nif_library_not_loaded).
