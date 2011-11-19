
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

-export([hexbin_to_bin/1, hexstr_to_list/1, bin_to_hexbin/1, list_to_hexstr/1, bits_to_target/1, endian_swap/1, bn2mpi_le/1, mpi2bn_le/1]).

-define(LOG256, 5.545177444479562).

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
    I = (B band 16#ffffff) bsl ((B bsr 24 - 3) bsl 3),
    <<I:256>>.

endian_swap(Bin) ->
    endian_swap(Bin, <<>>).

endian_swap(<<>>, Acc) ->
    Acc;
endian_swap(<<V:32/little, R/binary>>, Acc) ->
    endian_swap(R, <<Acc/binary, V:32/big>>).

bn2mpi_le(0) ->
    <<>>;
bn2mpi_le(BN) when BN < 0 ->
    MPI = bn2mpi_le(-BN),
    L = byte_size(MPI) - 1,
    <<H:L/bytes, LSB:8/unsigned>> = MPI,
    <<H/bytes, (LSB bor 128):8/unsigned>>;
bn2mpi_le(BN) when BN < 16#80 -> % Speed improvement for smaller numbers
    <<BN:8/unsigned>>;
bn2mpi_le(BN) when BN < 16#8000 ->
    <<BN:16/unsigned-little>>;
bn2mpi_le(BN) when BN < 16#800000 ->
    <<BN:24/unsigned-little>>;
bn2mpi_le(BN) when BN < 16#80000000 ->
    <<BN:32/unsigned-little>>;
bn2mpi_le(BN) ->
    MinBits = trunc(math:log(BN) / ?LOG256) * 8,
    Rest = BN bsr MinBits,
    if
        Rest =:= 0 ->
            <<BN:MinBits/unsigned-little>>;
        Rest < 128 ->
            <<BN:(MinBits+8)/unsigned-little>>;
        true ->
            <<BN:(MinBits+16)/unsigned-little>>
    end.

mpi2bn_le(<<>>) ->
    0;
mpi2bn_le(<<LSB:8/unsigned>>) ->
    if
        LSB < 128 -> LSB;
        true -> -(LSB band 127)
    end;
mpi2bn_le(MPI) ->
    Bits = bit_size(MPI),
    L = byte_size(MPI) - 1,
    <<H:L/bytes, LSB:8/unsigned>> = MPI,
    if
        LSB < 128 ->
            <<BN:Bits/unsigned-little>> = MPI,
            BN;
        true ->
            <<BN:Bits/unsigned-little>> = <<H:L/bytes, (LSB band 127):8/unsigned>>,
            -BN
    end.
