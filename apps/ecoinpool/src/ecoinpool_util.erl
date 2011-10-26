
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

-module(ecoinpool_util).

-export([hexbin_to_bin/1, hexstr_to_list/1, bin_to_hexbin/1, list_to_hexstr/1, bits_to_target/1]).

hexbin_to_bin(BinHex) ->
    binary:list_to_bin(hexstr_to_list(binary:bin_to_list(BinHex))).

hexstr_to_list(S) ->
    lists:reverse(hexstr_to_list(S, [])).

hexstr_to_list([], Acc) ->
    Acc;
hexstr_to_list([A, B | T], Acc) ->
    {ok, [V], []} = io_lib:fread("~16u", [A, B]),
    hexstr_to_list(T, [V | Acc]).

bin_to_hexbin(Bin) ->
    binary:list_to_bin(list_to_hexstr(binary:bin_to_list(Bin))).

list_to_hexstr(L) ->
    lists:flatten([io_lib:format("~2.16.0b", [X]) || X <- L]).

bits_to_target(B) ->
    (B band 16#ffffff) bsl ((B bsr 24 - 3) bsl 3).
