
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

-module(btc_protocol).

-include("btc_protocol_records.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([sample_tx/1, sample_header/0, sample_block/0]).
-endif.

-export([
    decode_header/1,
    encode_header/1,
    decode_tx/1,
    encode_tx/1,
    decode_script/1,
    encode_script/1,
    decode_block/1,
    encode_block/1,
    encode_auxpow/1,
    hash160_from_address/1
]).

-define(OP_TABLE, [
    % control
    op_nop, op_ver, op_if, op_notif, op_verif, op_vernotif, op_else,
    op_endif, op_verify, op_return,
    % stack ops
    op_toaltstack, op_fromaltstack, op_2drop, op_2dup, op_3dup, op_2over,
    op_2rot, op_2swap, op_ifdup, op_depth, op_drop, op_dup, op_nip, op_over,
    op_pick, op_roll, op_rot, op_swap, op_tuck,
    % splice ops
    op_cat, op_substr, op_left, op_right, op_size,
    % bit logic
    op_invert, op_and, op_or, op_xor, op_equal, op_equalverify,
    op_reserved1, op_reserved2,
    % numeric
    op_1add, op_1sub, op_2mul, op_2div, op_negate, op_abs, op_not, op_0notequal,
    op_add, op_sub, op_mul, op_div, op_mod, op_lshift, op_rshift,
    op_booland, op_boolor, op_numequal, op_numequalverify, op_numnotequal,
    op_lessthan, op_greaterthan, op_lessthanorequal, op_greaterthanorequal,
    op_min, op_max,
    op_within,
    % crypto
    op_ripemd160, op_sha1, op_sha256, op_hash160, op_hash256, op_codeseparator,
    op_checksig, op_checksigverify, op_checkmultisig, op_checkmultisigverify,
    % expansion
    op_nop1, op_nop2, op_nop3, op_nop4, op_nop5, op_nop6, op_nop7, op_nop8,
    op_nop9, op_nop10
]).

%% Decoding %%

decode_header(BData) ->
    <<
        Version:32/little,
        HashPrevBlock:32/bytes,
        HashMerkleRoot:32/bytes,
        Timestamp:32/unsigned-little,
        Bits:32/unsigned-little,
        Nonce:32/unsigned-little
    >> = BData,
    
    #btc_header{version=Version,
        hash_prev_block=HashPrevBlock,
        hash_merkle_root=HashMerkleRoot,
        timestamp=Timestamp,
        bits=Bits,
        nonce=Nonce}.

decode_var_int(<<16#ff, V:64/unsigned-little, T/binary>>) ->
    {V, T};
decode_var_int(<<16#fe, V:32/unsigned-little, T/binary>>) ->
    {V, T};
decode_var_int(<<16#fd, V:16/unsigned-little, T/binary>>) ->
    {V, T};
decode_var_int(<<V:8/unsigned, T/binary>>) ->
    {V, T}.

decode_var_list(BData, DecodeElementFun) ->
    {N, T} = decode_var_int(BData),
    decode_var_list(T, DecodeElementFun, N, []).

decode_var_list(T, _, 0, Acc) ->
    {Acc, T};
decode_var_list(BData, DecodeElementFun, N, Acc) ->
    {Element, T} = DecodeElementFun(BData),
    decode_var_list(T, DecodeElementFun, N-1, Acc ++ [Element]).

decode_var_str(BData) ->
    {Length, StrAndT} = decode_var_int(BData),
    <<Str:Length/bytes, T/binary>> = StrAndT,
    {Str, T}.

decode_tx(BData) ->
    <<Version:32/unsigned-little, T1/binary>> = BData,
    {TxIn, T2} = decode_var_list(T1, fun decode_tx_in/1),
    {TxOut, T3} = decode_var_list(T2, fun decode_tx_out/1),
    <<LockTime:32/unsigned-little, T4/binary>> = T3,
    {#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}, T4}.

decode_tx_in(BData) ->
    <<PrevOutputHash:32/bytes, PrevOutputIndex:32/unsigned-little, T1/binary>> = BData,
    {SignatureScript, T2} = decode_var_str(T1),
    <<Sequence:32/unsigned-little, T3/binary>> = T2,
    {#btc_tx_in{prev_output_hash=PrevOutputHash, prev_output_index=PrevOutputIndex, signature_script=SignatureScript, sequence=Sequence}, T3}.

decode_tx_out(BData) ->
    <<Value:64/unsigned-little, T1/binary>> = BData,
    {PKScript, T2} = decode_var_str(T1),
    {#btc_tx_out{value=Value, pk_script=PKScript}, T2}.

decode_script(BData) ->
    decode_script(BData, []).

decode_script(<<>>, Acc) ->
    Acc;
decode_script(<<0, T/binary>>, Acc) ->
    decode_script(T, Acc ++ [0]);
decode_script(<<L:8/unsigned, T1/binary>>, Acc) when L =< 75 ->
    <<Data:L/bytes, T2/binary>> = T1,
    decode_script(T2, Acc ++ [Data]);
decode_script(<<76, L:8/unsigned, T1/binary>>, Acc) ->
    <<Data:L/bytes, T2/binary>> = T1,
    decode_script(T2, Acc ++ [Data]);
decode_script(<<77, L:16/unsigned-little, T1/binary>>, Acc) ->
    <<Data:L/bytes, T2/binary>> = T1,
    decode_script(T2, Acc ++ [Data]);
decode_script(<<78, L:32/unsigned-little, T1/binary>>, Acc) ->
    <<Data:L/bytes, T2/binary>> = T1,
    decode_script(T2, Acc ++ [Data]);
decode_script(<<OPCode:8/unsigned, T/binary>>, Acc) ->
    decode_script(T, if
        OPCode =:= 79 -> Acc ++ [-1];
        OPCode =:= 80 -> Acc ++ [op_reserved];
        OPCode =< 96 -> Acc ++ [OPCode-80];
        OPCode =< 185 -> Acc ++ [lists:nth(OPCode-96, ?OP_TABLE)]; % Note: This uses erlang's constant pool
        true -> Acc ++ [op_invalidopcode]
    end).

decode_block(<<BHeader:80/bytes, BData/binary>>) ->
    {Txns, <<>>} = decode_var_list(BData, fun decode_tx/1),
    #btc_block{header=decode_header(BHeader), txns=Txns}.

%% Encoding %%

encode_header(BTCHeader) ->
    #btc_header{version=Version,
        hash_prev_block=HashPrevBlock,
        hash_merkle_root=HashMerkleRoot,
        timestamp=Timestamp,
        bits=Bits,
        nonce=Nonce} = BTCHeader,
    
    <<
        Version:32/little,
        HashPrevBlock:32/bytes,
        HashMerkleRoot:32/bytes,
        Timestamp:32/unsigned-little,
        Bits:32/unsigned-little,
        Nonce:32/unsigned-little
    >>.

encode_var_int(V) when V > 16#ffffffff ->
    <<16#ff, V:64/unsigned-little>>;
encode_var_int(V) when V > 16#ffff ->
    <<16#fe, V:32/unsigned-little>>;
encode_var_int(V) when V > 16#fd ->
    <<16#fd, V:16/unsigned-little>>;
encode_var_int(V) ->
    <<V:8/unsigned>>.

encode_var_list(Elements, EncodeElementFun) ->
    BLength = encode_var_int(length(Elements)),
    encode_var_list(Elements, EncodeElementFun, BLength).

encode_var_list([], _, Acc) ->
    Acc;
encode_var_list([H|T], EncodeElementFun, Acc) ->
    BElement = if % Skip already encoded parts
        is_binary(H) -> H;
        true -> EncodeElementFun(H)
    end,
    encode_var_list(T, EncodeElementFun, <<Acc/binary, BElement/binary>>).

encode_var_str(Str) ->
    BLength = encode_var_int(byte_size(Str)),
    <<BLength/binary, Str/binary>>.

encode_tx(#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}) ->
    BTxIn = encode_var_list(TxIn, fun encode_tx_in/1),
    BTxOut = encode_var_list(TxOut, fun encode_tx_out/1),
    <<Version:32/unsigned-little, BTxIn/binary, BTxOut/binary, LockTime:32/unsigned-little>>.

encode_tx_in(#btc_tx_in{prev_output_hash=PrevOutputHash, prev_output_index=PrevOutputIndex, signature_script=SignatureScript, sequence=Sequence}) ->
    BSignatureScript = encode_var_str(
        if % Skip already encoded script
            is_binary(SignatureScript) -> SignatureScript;
            true -> encode_script(SignatureScript)
        end
    ),
    <<PrevOutputHash:32/bytes, PrevOutputIndex:32/unsigned-little, BSignatureScript/binary, Sequence:32/unsigned-little>>.

encode_tx_out(#btc_tx_out{value=Value, pk_script=PKScript}) ->
    BPKScript = encode_var_str(
        if % Skip already encoded script
            is_binary(PKScript) -> PKScript;
            true -> encode_script(PKScript)
        end
    ),
    <<Value:64/unsigned-little, BPKScript/binary>>.

encode_script(Script) ->
    encode_script(Script, <<>>).

encode_script([], Acc) ->
    Acc;
encode_script([H|T], Acc) ->
    encode_script(T, if
        is_integer(H) ->
            case H of
                0 -> <<Acc/binary, 0>>;
                -1 -> <<Acc/binary, 79>>;
                V when V >= 1, V =< 16 -> <<Acc/binary, (V+80):8/unsigned>>;
                V -> BV = encode_var_str(ecoinpool_util:bn2mpi_le(V)), <<Acc/binary, BV/binary>>
            end;
        is_binary(H) ->
            Size = byte_size(H),
            if
                Size =< 75 -> <<Acc/binary, Size:8/unsigned, H/binary>>;
                Size =< 255 -> <<Acc/binary, 76, Size:8/unsigned, H/binary>>;
                Size =< 65535 -> <<Acc/binary, 77, Size:16/unsigned-little, H/binary>>;
                Size =< 4294967295 -> <<Acc/binary, 78, Size:32/unsigned-little, H/binary>>
            end;
        is_atom(H) ->
            case H of
                op_false -> <<Acc/binary, 0>>;
                op_reserved -> <<Acc/binary, 80>>;
                op_true -> <<Acc/binary, 81>>;
                _ -> OPCode = lookup_op(H), <<Acc/binary, OPCode:8/unsigned>>
            end
    end).

lookup_op(OP) -> lookup_op(OP, ?OP_TABLE, 0).

lookup_op(_, [], _)  -> 255;
lookup_op(OP, [OP|_], Index) -> Index+97;
lookup_op(OP, [_|T], Index) -> lookup_op(OP, T, Index+1).

encode_block(#btc_block{header=Header, txns=Txns}) ->
    BHeader = encode_header(Header),
    BData = encode_var_list(Txns, fun encode_tx/1),
    <<BHeader:80/bytes, BData/binary>>.

encode_auxpow(#btc_auxpow{coinbase_tx=CoinbaseTx, block_hash=BlockHash, tx_tree_branches=TxTreeBranches, tx_index=TxIndex, aux_tree_branches=AuxTreeBranches, aux_index=AuxIndex, parent_header=ParentHeader}) ->
    BCoinbaseTx = if
        is_binary(CoinbaseTx) -> CoinbaseTx;
        true -> encode_tx(CoinbaseTx)
    end,
    BTxTreeBranches = encode_var_list(TxTreeBranches, undefined),
    BAuxTreeBranches = encode_var_list(AuxTreeBranches, undefined),
    BParentHeader = if
        is_binary(ParentHeader) -> ParentHeader;
        true -> encode_header(ParentHeader)
    end,
    <<BCoinbaseTx/binary, BlockHash/binary, BTxTreeBranches/binary, TxIndex:32/unsigned-little, BAuxTreeBranches/binary, AuxIndex:32/unsigned-little, BParentHeader/binary>>.

hash160_from_address(BTCAddress) ->
    try
        <<Network:8/unsigned, Hash160:20/bytes, Checksum:32/unsigned>> = base58:decode(BTCAddress),
        <<_:28/bytes, Checksum:32/unsigned-little>> = ecoinpool_hash:dsha256_hash(<<Network:8/unsigned, Hash160:20/bytes>>),
        Hash160
    catch error:_ ->
        error(invalid_bitcoin_address)
    end.

%% Unit Testing %%

-ifdef(TEST).

sample_tx(1) ->
    base64:decode(<<"AQAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP////8IBJoRDhoC9AX/////AVC1BioBAAAAQ0EE/8r3eNPQY6kXEvqfjkJwchdWNMLyGLYBiUEqt82c3d8zHXgRQJ5N9yRH2OFMr0m2kyAUv/Pw3YNjT3rRn7ITAKwAAAAA">>);
sample_tx(2) ->
    base64:decode(<<"AQAAAAHIHImp3G2FOm3yUsKXjqKIj8gar+Br2KUXjqcrFILAKwEAAACKRzBEAiA5s70M4ZHgmz6DU6Omrvmfu6qQrC9+At8WR0z5xcnhsQIgSICe8IJuHZlAB8tbDYNcgx3dcHgde5LWTvpe6lWnz/MBQQRIULR1oM/Zg+cIs1olXbEezeRR8lxCFC+vz+l+ZkeRzeYDOsYmxRufhq1+4jhaw128yDppk6TCfvpfQ9lQcb/k/////wJwHuQAAAAAABl2qRQeNWtjIrBE3IgSK9AtlCQQ/8+0NoisgMJEbgAAAAAZdqkUDfGdVdogCQq/joWhw6CotKRR2aCIrAAAAAA=">>);
sample_tx(3) ->
    base64:decode(<<"AQAAAAHLPfR4aPWkowO1vRPuJlQtxwsjwbluIoCSc2O9mu6R2QAAAACMSTBGAiEA2Qv/GS5/vSgee7F+HJUhE20dZ3yM1atRAIsr/dJabRwCIQCVNqaQLqipiGvBIrrqTdVkOfTiJ4NOfMAOVYVjZMVkWQFBBD/Ws4Atipx72E25O/PTIiuQpm5pgKMiOqv6e+cMdyAEJ9BmRbdToOg3oVC9jJ5868gZJ4Mrbrx40qyQV2Cfh+b/////AsDYpwAAAAAAGXapFAhMoC1OfWVGV/AzFZMrABoooftViKyAzAYCAAAAABl2qRTYhH+LF38RCXoLTrsULa0qw/sOlIisAAAAAA==">>);
sample_tx(4) ->
    base64:decode(<<"AQAAAAH1fes7Ej1fkfSSwHKQN1lz62FzaB/Ueap9IkQ0jhIK6gAAAABIRzBEAiAGOeUVu+UefkDn/wHCijutAoQXgfjPYbT4yvHoh2i4FAIgK1pD2+rKUpKrrWAI3uXjMyEtPjuhkqMwcaIFCCBfu44B/////wLfXuEAAAAAAENBBKObnk+9IT7yS7m+ad5KEY3QZECC5HwB/ZFZ04Y3uD+83BFaXW6XBYagEtHP4+OosaPQTnY73FoHHA6CfAvYNKWsQEIPAAAAAAAZdqkUNnJR4xF0uMdKq07yukLII2tOea+IrAAAAAA=">>).

sample_script() ->
    <<_:194/bytes, SampleScript:25/bytes, _/binary>> = sample_tx(2),
    SampleScript.

sample_header() ->
    base64:decode(<<"AQAAAGpJl3mr0KHNIp5GxjMf1fuqR1/qIRK3OIAGAAAAAAAARyDUB5doFsGHiCruAnPtGoxaosJyISVkCbtLbEzHA/l2JMpOmhEOGkFECaA=">>).

sample_block() ->
    H = sample_header(),
    Tx1 = sample_tx(1),
    Tx2 = sample_tx(2),
    Tx3 = sample_tx(3),
    Tx4 = sample_tx(4),
    <<H/binary, 4, Tx1/binary, Tx2/binary, Tx3/binary, Tx4/binary>>.

var_int_test_() ->
    D1 = 4294967297, E1 = <<255,1,0,0,0,1,0,0,0>>,
    D2 = 131074, E2 = <<254,2,0,2,0>>,
    D3 = 771, E3 = <<253,3,3>>,
    D4 = 252, E4 = <<252>>,
    [
        ?_assertEqual({D1, <<>>}, decode_var_int(E1)),
        ?_assertEqual({D2, <<>>}, decode_var_int(E2)),
        ?_assertEqual({D3, <<>>}, decode_var_int(E3)),
        ?_assertEqual({D4, <<>>}, decode_var_int(E4)),
        ?_assertEqual(E1, encode_var_int(D1)),
        ?_assertEqual(E2, encode_var_int(D2)),
        ?_assertEqual(E3, encode_var_int(D3)),
        ?_assertEqual(E4, encode_var_int(D4))
    ].

var_list_test_() ->
    [
        ?_assertEqual({[], <<"x">>}, decode_var_list(<<0,"x">>, unused)),
        ?_assertEqual({[<<"abc">>], <<"xyz">>}, decode_var_list(<<1,"abcxyz">>, fun (<<X:3/bytes, T/binary>>) -> {X, T} end)),
        ?_assertEqual({[1,2,3], <<"x">>}, decode_var_list(<<3,1,2,3,"x">>, fun decode_var_int/1)),
        ?_assertEqual(<<0>>, encode_var_list([], unused)),
        ?_assertEqual(<<1,"abc">>, encode_var_list([<<"abc">>], fun (X) -> X end)),
        ?_assertEqual(<<3,1,2,3>>, encode_var_list([1,2,3], fun encode_var_int/1))
    ].

var_str_test_() ->
    [
        ?_assertEqual({<<"demo">>, <<"123">>}, decode_var_str(<<4,"demo123">>)),
        ?_assertEqual(<<4,"demo">>, encode_var_str(<<"demo">>))
    ].

tx_test_() ->
    ETx = sample_tx(1),
    DTx = #btc_tx{
        version = 1,
        tx_in = [
            #btc_tx_in{
                prev_output_hash = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
                prev_output_index = 16#ffffffff,
                signature_script = <<4,154,17,14,26,2,244,5>>,
                sequence = 16#ffffffff
            }
        ],
        tx_out = [
            #btc_tx_out{
                value = 5000050000,
                pk_script = base64:decode(<<"QQT/yvd409BjqRcS+p+OQnByF1Y0wvIYtgGJQSq3zZzd3zMdeBFAnk33JEfY4UyvSbaTIBS/8/Ddg2NPetGfshMArA==">>)
            }
        ],
        lock_time = 0
    },
    [
        ?_assertEqual({DTx, <<>>}, decode_tx(ETx)),
        ?_assertEqual(ETx, encode_tx(DTx))
    ].

header_test_() ->
    EHeader = sample_header(),
    DHeader = #btc_header{
        version = 1,
        hash_prev_block = base64:decode(<<"akmXeavQoc0inkbGMx/V+6pHX+ohErc4gAYAAAAAAAA=">>),
        hash_merkle_root = base64:decode(<<"RyDUB5doFsGHiCruAnPtGoxaosJyISVkCbtLbEzHA/k=">>),
        timestamp = 1321870454,
        bits = 437129626,
        nonce = 2684961857
    },
    [
        ?_assertEqual(DHeader, decode_header(EHeader)),
        ?_assertEqual(EHeader, encode_header(DHeader))
    ].

script_test_() ->
    EScript = sample_script(),
    DScript = [op_dup, op_hash160, base64:decode(<<"HjVrYyKwRNyIEivQLZQkEP/PtDY=">>), op_equalverify, op_checksig],
    [
        ?_assertEqual(DScript, decode_script(EScript)),
        ?_assertEqual(EScript, encode_script(DScript))
    ].

hash160_from_address_test_() ->
    [
        ?_assertEqual(base64:decode(<<"N/PfYVVqkAwRSc47ZI/+TTZMEpU=">>), hash160_from_address(<<"166rK7eEVgnGvs9aA7jvu8NoPv8KzbPQ3L">>)),
        ?_assertError(invalid_bitcoin_address, hash160_from_address(<<"166rK7eEVgnGvs9aA7jvu8NoPv8KzbPQ3M">>))
    ].

encode_auxpow_test() ->
    EAuxPOW = base64:decode(<<"AQAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP////83BEttCxoDRbIAUiz6vm1t9PgsbckHZOle+WNcwqSrg4YrqhbT1iWOlPGlOFOQN0kBAAAAAAAAAP////8BWhNWKgEAAABDQQSKuGvFWJdPA1AObmrj/iAuKXxBMm3i0trgHhYTnFaawlsMBgC6+TJT/tGzwZKttrsZnPGrV140gzm0T1mSxwTPrAAAAAAn8KtiOt5HXpwN4tQEQmbmWxSuBmMGJ7G1IAAAAAAAAAX5sGhq0WwiZ8xTBoel7dwxqSCGNxb7vNhMJQ25IHqi3hysmwX/aJ/fZUAqEAaqOgT3jaG1e2Lq+ADAGw5IA2cW8tH7fHUYZPkos3eNfblB+CdOpVo/AcrNCe1KMyl0S45wnoGRrDIbjq1BnZOD+qlE6ukuDHZ7/XFXtiWpJoSkB4j4tkEOQaVNpJP90NoIqyIoCWZFZH+doHbK1C4mW/MuAAAAAAAAAAAAAQAAAEyrZVt1wzmfhMbzPXs2PSYpWQPh3PrtWdoBAAAAAAAAXWb6XgsqHvp1esikEjISO0HGWIJsAtxLrASDiRMmw/mubJlOS20LGmSgcoo=">>),
    AuxHash = binary_part(EAuxPOW, {57, 32}),
    DAuxPOW = #btc_auxpow{
        coinbase_tx = #btc_tx{
            tx_in = [
                #btc_tx_in{
                    prev_output_hash = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
                    prev_output_index = 16#ffffffff,
                    signature_script = [436956491, 45637, 2, <<250,190,109,109, AuxHash/binary, 1,0,0,0,0,0,0,0>>],
                    sequence = 16#ffffffff
                }
            ],
            tx_out = [
                #btc_tx_out{
                    value = 5005251418,
                    pk_script = base64:decode(<<"QQSKuGvFWJdPA1AObmrj/iAuKXxBMm3i0trgHhYTnFaawlsMBgC6+TJT/tGzwZKttrsZnPGrV140gzm0T1mSxwTPrA==">>)
                }
            ]
        },
        block_hash = base64:decode(<<"J/CrYjreR16cDeLUBEJm5lsUrgZjBiextSAAAAAAAAA=">>),
        tx_tree_branches = [
            binary_part(EAuxPOW, {215, 32}),
            binary_part(EAuxPOW, {247, 32}),
            binary_part(EAuxPOW, {279, 32}),
            binary_part(EAuxPOW, {311, 32}),
            binary_part(EAuxPOW, {343, 32})
        ],
        parent_header = #btc_header{
            hash_prev_block = base64:decode(<<"TKtlW3XDOZ+ExvM9ezY9JilZA+Hc+u1Z2gEAAAAAAAA=">>),
            hash_merkle_root = base64:decode(<<"XWb6XgsqHvp1esikEjISO0HGWIJsAtxLrASDiRMmw/k=">>),
            timestamp = 1318677678,
            bits = 436956491,
            nonce = 2322767972
        }
    },
    ?assertEqual(EAuxPOW, encode_auxpow(DAuxPOW)).

-endif.
