
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

-export([hexbin_to_bin/1, hexstr_to_list/1, bin_to_hexbin/1, list_to_hexstr/1, bits_to_target/1, endian_swap/1, byte_reverse/1, bn2mpi_le/1, mpi2bn_le/1, send_http_req/3, new_random_uuid/0]).

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

byte_reverse(B) ->
    Bits = bit_size(B),
    <<V:Bits/big>> = B,
    <<V:Bits/little>>.

bn2mpi_le(0) ->
    <<>>;
bn2mpi_le(BN) when BN < 0 ->
    MPI = binary:encode_unsigned(-BN, little),
    L = byte_size(MPI) - 1,
    <<H:L/bytes, LSB:8/unsigned>> = MPI,
    if
        LSB < 128 -> <<H/bytes, (LSB bor 128):8/unsigned>>;
        true -> <<MPI/binary, 128>>
    end;
bn2mpi_le(BN) ->
    MPI = binary:encode_unsigned(BN, little),
    L = byte_size(MPI) - 1,
    <<_:L/bytes, LSB:8/unsigned>> = MPI,
    if
        LSB < 128 -> MPI;
        true -> <<MPI/binary, 0>>
    end.

mpi2bn_le(<<>>) ->
    0;
mpi2bn_le(<<LSB:8/unsigned>>) ->
    if
        LSB < 128 -> LSB;
        true -> -(LSB band 127)
    end;
mpi2bn_le(MPI) ->
    L = byte_size(MPI) - 1,
    <<H:L/bytes, LSB:8/unsigned>> = MPI,
    if
        LSB < 128 ->
            binary:decode_unsigned(MPI, little);
        true ->
            -binary:decode_unsigned(<<H:L/bytes, (LSB band 127):8/unsigned>>, little)
    end.

send_http_req(URL, Auth, PostData) ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    ibrowse:send_req(URL, [{"User-Agent", "ecoinpool/" ++ VSN}, {"Accept", "application/json"}], post, PostData, [{basic_auth, Auth}, {content_type, "application/json"}]).

new_random_uuid() ->
    R1 = random:uniform(16#ffffffff)-1,
    R2 = random:uniform(16#ffffffff)-1,
    R3 = random:uniform(16#ffffffff)-1,
    R4 = random:uniform(16#ffffffff)-1,
    bin_to_hexbin(<<R1:32, R2:32, R3:32, R4:32>>).
