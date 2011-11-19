
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

-export([decode_btc_header/1, encode_btc_header/1, decode_btc_tx/1, encode_btc_tx/1, decode_script/1, encode_script/1]).

-define(OP_TABLE, [
    % control
    op_nop, op_ver, op_if, op_notif, op_verif, op_vernotif, op_else,
    op_endif, op_verify, op_return,
    % stack ops
    op_toaltstack, op_fromaltstack, op_2drop, op_2dup, op_3dup, op_2over,
    op_2rot, op_2swap, p_ifdup, op_depth, op_drop, op_dup, op_nip, op_over,
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

decode_btc_header(BData) ->
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

decode_btc_tx(BData) ->
    <<Version:32/unsigned-little, T1/binary>> = BData,
    {TxIn, T2} = decode_var_list(T1, fun decode_btc_tx_in/1),
    {TxOut, T3} = decode_var_list(T2, fun decode_btc_tx_out/1),
    <<LockTime:32/unsigned-little, T4/binary>> = T3,
    {#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}, T4}.

decode_btc_tx_in(BData) ->
    <<PrevOutputHash:32/bytes, PrevOutputIndex:32/unsigned-little, T1/binary>> = BData,
    {SignatureScript, T2} = decode_var_str(T1),
    <<Sequence:32/unsigned-little, T3/binary>> = T2,
    {#btc_tx_in{prev_output_hash=PrevOutputHash, prev_output_index=PrevOutputIndex, signature_script=SignatureScript, sequence=Sequence}, T3}.

decode_btc_tx_out(BData) ->
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

%% Encoding %%

encode_btc_header(BTCHeader) ->
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
    BElement = EncodeElementFun(H),
    encode_var_list(T, EncodeElementFun, <<Acc/binary, BElement/binary>>).

encode_var_str(Str) ->
    BLength = encode_var_int(byte_size(Str)),
    <<BLength/binary, Str/binary>>.

encode_btc_tx(#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}) ->
    BTxIn = encode_var_list(TxIn, fun encode_btc_tx_in/1),
    BTxOut = encode_var_list(TxOut, fun encode_btc_tx_out/1),
    <<Version:32/unsigned-little, BTxIn/binary, BTxOut/binary, LockTime:32/unsigned-little>>.

encode_btc_tx_in(#btc_tx_in{prev_output_hash=PrevOutputHash, prev_output_index=PrevOutputIndex, signature_script=SignatureScript, sequence=Sequence}) ->
    BSignatureScript = encode_var_str(SignatureScript),
    <<PrevOutputHash:32/bytes, PrevOutputIndex:32/unsigned-little, BSignatureScript/binary, Sequence:32/unsigned-little>>.

encode_btc_tx_out(#btc_tx_out{value=Value, pk_script=PKScript}) ->
    BPKScript = encode_var_str(PKScript),
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
