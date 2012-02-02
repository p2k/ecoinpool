
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ebitcoin.
%%
%% ebitcoin is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ebitcoin is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ebitcoin.  If not, see <http://www.gnu.org/licenses/>.
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
    encode_main_header/1,
    decode_tx/1,
    encode_tx/1,
    decode_script/1,
    encode_script/1,
    decode_block/1,
    encode_block/1,
    decode_auxpow/1,
    encode_auxpow/1,
    decode_net_addr/1,
    encode_net_addr/1,
    decode_addr/1,
    encode_addr/1,
    decode_version/1,
    encode_version/1,
    decode_command/1,
    encode_command/1,
    decode_inv_vect/1,
    encode_inv_vect/1,
    decode_inv/1,
    encode_inv/1,
    decode_getdata/1,
    encode_getdata/1,
    decode_getblocks/1,
    encode_getblocks/1,
    decode_getheaders/1,
    encode_getheaders/1,
    decode_headers/1,
    encode_headers/1,
    hash160_from_address/1,
    get_hash/1,
    verify_block_basic/1
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

% Note: All functions always return a tuple {Object, Tail}

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

decode_hash(<<Hash:256/little, T/binary>>) ->
    {<<Hash:256/big>>, T}.

decode_header(BData) ->
    <<
        Version:32/little,
        HashPrevBlock:256/little,
        HashMerkleRoot:256/little,
        Timestamp:32/unsigned-little,
        Bits:32/unsigned-little,
        Nonce:32/unsigned-little,
        T1/binary
    >> = BData,
    
    {AuxPOW, T2} = if
        Version band 16#100 =/= 0 -> decode_auxpow(T1);
        true -> {undefined, T1}
    end,
    
    {#btc_header{
        version = Version,
        hash_prev_block = <<HashPrevBlock:256/big>>,
        hash_merkle_root = <<HashMerkleRoot:256/big>>,
        timestamp = Timestamp,
        bits = Bits,
        nonce = Nonce,
        auxpow = AuxPOW}, T2}.

decode_long_header(BData) ->
    {Header, T1} = decode_header(BData),
    {NTx, T2} = decode_var_int(T1),
    {{Header, NTx}, T2}.

decode_tx(<<Version:32/unsigned-little, T1/binary>>) ->
    {TxIn, T2} = decode_var_list(T1, fun decode_tx_in/1),
    {TxOut, T3} = decode_var_list(T2, fun decode_tx_out/1),
    <<LockTime:32/unsigned-little, T4/binary>> = T3,
    {#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}, T4}.

decode_tx_in(<<PrevOutputHash:256/little, PrevOutputIndex:32/unsigned-little, T1/binary>>) ->
    {SignatureScript, <<Sequence:32/unsigned-little, T2/binary>>} = decode_var_str(T1),
    {#btc_tx_in{prev_output_hash = <<PrevOutputHash:256/big>>, prev_output_index = PrevOutputIndex, signature_script = SignatureScript, sequence = Sequence}, T2}.

decode_tx_out(<<Value:64/unsigned-little, T1/binary>>) ->
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

decode_block(BData) ->
    {Header, T1} = decode_header(BData),
    {Txns, T2} = decode_var_list(T1, fun decode_tx/1),
    {#btc_block{header=Header, txns=Txns}, T2}.

decode_auxpow(BData) ->
    {CoinbaseTx, <<BlockHash:256/little, T1/binary>>} = decode_tx(BData),
    {TxTreeBranches, <<TxIndex:32/unsigned-little, T2/binary>>} = decode_var_list(T1, fun decode_hash/1),
    {AuxTreeBranches, <<AuxIndex:32/unsigned-little, T3/binary>>} = decode_var_list(T2, fun decode_hash/1),
    {ParentHeader, T4} = decode_header(T3),
    {#btc_auxpow{
        coinbase_tx = CoinbaseTx,
        block_hash = <<BlockHash:256/big>>,
        tx_tree_branches = TxTreeBranches,
        tx_index = TxIndex,
        aux_tree_branches = AuxTreeBranches,
        aux_index = AuxIndex,
        parent_header = ParentHeader
    }, T4}.

decode_ip(<<0,0,0,0,0,0,0,0,0,0,255,255,A,B,C,D, T/binary>>) ->
    {{ip4, lists:flatten(io_lib:format("~b.~b.~b.~b", [A,B,C,D]))}, T};
decode_ip(<<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16, T/binary>>) ->
    L = [A,B,C,D,E,F,G,H],
    BestZSeq = lists:foldl(
        fun
            (_, {7, {0, 0},   Best}) -> Best;
            (0, {7, {ZP, ZL}, Best={_, BZL}}) -> if ZL+1 > BZL -> {ZP, ZL+1}; true -> Best end;
            (_, {7, {ZP, ZL}, Best={_, BZL}}) -> if ZL > 1, ZL > BZL -> {ZP, ZL}; true -> Best end;
            (0, {P, {0, 0},   Best}) -> {P+1, {P, 1}, Best};
            (0, {P, {ZP, ZL}, Best}) -> {P+1, {ZP, ZL+1}, Best};
            (_, {P, {0, 0},   Best}) -> {P+1, {0, 0}, Best};
            (_, {P, {ZP, ZL}, Best={_, BZL}}) -> {P+1, {0, 0}, if ZL > 1, ZL > BZL -> {ZP, ZL}; true -> Best end}
        end,
        {0, {0, 0}, {0, 0}},
        L
    ),
    Encoded = [io_lib:format("~.16b", [X]) || X <- L],
    Compacted = case BestZSeq of
        {0, 0}  -> Encoded;
        {0, 8}  -> ["", "", ""];
        {0, LN} -> ["", ""] ++ lists:nthtail(LN, Encoded);
        {P, LN} when P+LN =:= 8 -> lists:sublist(Encoded, P) ++ ["", ""];
        {P, LN} -> lists:sublist(Encoded, P) ++ [""] ++ lists:nthtail(P+LN, Encoded)
    end,
    {{ip6, lists:flatten(string:join(Compacted, ":"))}, T}.

decode_net_addr(<<Time:32/unsigned-little, Services:64/unsigned-little, T1/binary>>) ->
    {IP, <<Port:16/unsigned-big, T2/binary>>} = decode_ip(T1),
    {#btc_net_addr{time=Time, services=Services, ip=IP, port=Port}, T2}.

decode_version_net_addr(<<Services:64/unsigned-little, T1/binary>>) ->
    {IP, <<Port:16/unsigned-big, T2/binary>>} = decode_ip(T1),
    {#btc_net_addr{services=Services, ip=IP, port=Port}, T2}.

decode_addr(BAddr) ->
    {AddrList, T} = decode_var_list(BAddr, fun decode_net_addr/1),
    {#btc_addr{addr_list=AddrList}, T}.

decode_version(<<V:32/little, Services:64/unsigned-little, Timestamp:64/little, T1/binary>>) ->
    case decode_version_net_addr(T1) of
        {AddrRecv, <<>>} ->
            #btc_version{
                version=V,
                services=Services,
                timestamp=Timestamp,
                addr_recv=AddrRecv
            };
        {AddrRecv, T2} ->
            {AddrFrom, <<Nonce:64/unsigned-little, T3/binary>>} = decode_version_net_addr(T2),
            {SubVersionNum, T4} = decode_var_str(T3),
            {StartHeight, T5} = case T4 of
                <<SH:32/little, TT5/binary>> -> {SH, TT5};
                _ -> {undefined, T4}
            end,
            {#btc_version{
                version=V,
                services=Services,
                timestamp=Timestamp,
                addr_recv=AddrRecv,
                addr_from=AddrFrom,
                nonce=Nonce,
                sub_version_num=SubVersionNum,
                start_height=StartHeight
            }, T5}
    end.

decode_command(BCommand) ->
    list_to_atom(string:strip(binary:bin_to_list(BCommand), right, 0)).

decode_inv_vect(<<Type:32/unsigned-little, Hash:256/little, T/binary>>) ->
    DType = case Type of
        0 -> error;
        1 -> msg_tx;
        2 -> msg_block;
        _ -> Type
    end,
    {#btc_inv_vect{type = DType, hash = <<Hash:256/big>>}, T}.

decode_inv(BInv) ->
    {Inventory, T} = decode_var_list(BInv, fun decode_inv_vect/1),
    {#btc_inv{inventory=Inventory}, T}.

decode_getdata(BGetData) ->
    {Inventory, T} = decode_var_list(BGetData, fun decode_inv_vect/1),
    {#btc_getdata{inventory=Inventory}, T}.

decode_getblocks(<<Version:32/unsigned-little, BGetBlocks/binary>>) ->
    {BlockLocatorHashes, <<HashStop:256/little, T/binary>>} = decode_var_list(BGetBlocks, fun decode_hash/1),
    {#btc_getblocks{version = Version, block_locator_hashes = BlockLocatorHashes, hash_stop = <<HashStop:256/big>>}, T}.

decode_getheaders(<<Version:32/unsigned-little, BGetHeaders/binary>>) ->
    {BlockLocatorHashes, <<HashStop:256/little, T/binary>>} = decode_var_list(BGetHeaders, fun decode_hash/1),
    {#btc_getheaders{version = Version, block_locator_hashes = BlockLocatorHashes, hash_stop = <<HashStop:256/big>>}, T}.

decode_headers(BHeaders) ->
    {LongHeaders, T} = decode_var_list(BHeaders, fun decode_long_header/1),
    {#btc_headers{long_headers=LongHeaders}, T}.

%% Encoding %%

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
    encode_var_list(Elements, EncodeElementFun, true, BLength).

encode_var_list_noskip(Elements, EncodeElementFun) ->
    BLength = encode_var_int(length(Elements)),
    encode_var_list(Elements, EncodeElementFun, false, BLength).

encode_var_list([], _, _, Acc) ->
    Acc;
encode_var_list([H|T], EncodeElementFun, true, Acc) ->
    BElement = if % Skip already encoded parts
        is_binary(H) -> H;
        true -> EncodeElementFun(H)
    end,
    encode_var_list(T, EncodeElementFun, true, <<Acc/binary, BElement/binary>>);
encode_var_list([H|T], EncodeElementFun, false, Acc) ->
    BElement = EncodeElementFun(H),
    encode_var_list(T, EncodeElementFun, false, <<Acc/binary, BElement/binary>>).

encode_var_str(Str) ->
    BLength = encode_var_int(byte_size(Str)),
    <<BLength/binary, Str/binary>>.

encode_hash(<<Hash:256/big>>) ->
    <<Hash:256/little>>.

encode_header(BTCHeader) ->
    #btc_header{
        version = Version,
        hash_prev_block = <<HashPrevBlock:256/big>>,
        hash_merkle_root = <<HashMerkleRoot:256/big>>,
        timestamp = Timestamp,
        bits = Bits,
        nonce = Nonce,
        auxpow = AuxPOW
    } = BTCHeader,
    
    BAuxPOW = if
        Version band 16#100 =/= 0 -> encode_auxpow(AuxPOW);
        true -> <<>>
    end,
    
    <<
        Version:32/little,
        HashPrevBlock:256/little,
        HashMerkleRoot:256/little,
        Timestamp:32/unsigned-little,
        Bits:32/unsigned-little,
        Nonce:32/unsigned-little,
        BAuxPOW/binary
    >>.

encode_main_header(BTCHeader) ->
    #btc_header{
        version = Version,
        hash_prev_block = <<HashPrevBlock:256/big>>,
        hash_merkle_root = <<HashMerkleRoot:256/big>>,
        timestamp = Timestamp,
        bits = Bits,
        nonce = Nonce
    } = BTCHeader,
    
    <<
        Version:32/little,
        HashPrevBlock:256/little,
        HashMerkleRoot:256/little,
        Timestamp:32/unsigned-little,
        Bits:32/unsigned-little,
        Nonce:32/unsigned-little
    >>.

encode_long_header({BTCHeader, NTx}) ->
    BHeader = encode_header(BTCHeader),
    BNTx = encode_var_int(NTx),
    <<BHeader/binary, BNTx/binary>>.

encode_tx(#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}) ->
    BTxIn = encode_var_list(TxIn, fun encode_tx_in/1),
    BTxOut = encode_var_list(TxOut, fun encode_tx_out/1),
    <<Version:32/unsigned-little, BTxIn/binary, BTxOut/binary, LockTime:32/unsigned-little>>.

encode_tx_in(#btc_tx_in{prev_output_hash = <<PrevOutputHash:256/big>>, prev_output_index = PrevOutputIndex, signature_script = SignatureScript, sequence = Sequence}) ->
    BSignatureScript = encode_var_str(
        if % Skip already encoded script
            is_binary(SignatureScript) -> SignatureScript;
            true -> encode_script(SignatureScript)
        end
    ),
    <<PrevOutputHash:256/little, PrevOutputIndex:32/unsigned-little, BSignatureScript/binary, Sequence:32/unsigned-little>>.

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
    BTxns = encode_var_list(Txns, fun encode_tx/1),
    <<BHeader/binary, BTxns/binary>>.

encode_auxpow(AuxPOW) ->
    #btc_auxpow{
        coinbase_tx = CoinbaseTx,
        block_hash = <<BlockHash:256/big>>,
        tx_tree_branches = TxTreeBranches,
        tx_index = TxIndex,
        aux_tree_branches = AuxTreeBranches,
        aux_index = AuxIndex,
        parent_header = ParentHeader
    } = AuxPOW,
    BCoinbaseTx = if
        is_binary(CoinbaseTx) -> CoinbaseTx;
        true -> encode_tx(CoinbaseTx)
    end,
    BTxTreeBranches = encode_var_list_noskip(TxTreeBranches, fun encode_hash/1),
    BAuxTreeBranches = encode_var_list_noskip(AuxTreeBranches, fun encode_hash/1),
    BParentHeader = if
        is_binary(ParentHeader) -> ParentHeader;
        true -> encode_header(ParentHeader)
    end,
    <<
        BCoinbaseTx/binary,
        BlockHash:256/little,
        BTxTreeBranches/binary,
        TxIndex:32/unsigned-little,
        BAuxTreeBranches/binary,
        AuxIndex:32/unsigned-little,
        BParentHeader/binary
    >>.

encode_ip({ip4, DotQuad}) ->
    {ok, [A,B,C,D], []} = io_lib:fread("~d.~d.~d.~d", DotQuad),
    <<0,0,0,0,0,0,0,0,0,0,255,255,A,B,C,D>>;
encode_ip({ip6, Addr}) ->
    DecodeSections = fun (Str) -> lists:map(fun (X) -> {ok, [V], []} = io_lib:fread("~16u", X), V end, string:tokens(Str, ":")) end,
    [A,B,C,D,E,F,G,H] = case string:str(Addr, "::") of
        0 ->
            DecodeSections(Addr);
        ExpPoint ->
            {FS, RS} = lists:split(ExpPoint, Addr),
            DF = DecodeSections(FS),
            DR = DecodeSections(RS),
            DF ++ lists:duplicate(8 - length(DF) - length(DR), 0) ++ DR
    end,
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>;
encode_ip({A, B, C, D}) ->
    <<0,0,0,0,0,0,0,0,0,0,255,255,A,B,C,D>>;
encode_ip({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.

encode_net_addr(#btc_net_addr{time=Time, services=Services, ip=DecodedIP, port=Port}) ->
    IP = encode_ip(DecodedIP),
    <<Time:32/unsigned-little, Services:64/unsigned-little, IP:16/bytes, Port:16/unsigned-big>>.

encode_version_net_addr(#btc_net_addr{services=Services, ip=DecodedIP, port=Port}) ->
    IP = encode_ip(DecodedIP),
    <<Services:64/unsigned-little, IP:16/bytes, Port:16/unsigned-big>>.

encode_addr(#btc_addr{addr_list=AddrList}) ->
    encode_var_list(AddrList, fun encode_net_addr/1).

encode_version(Version) ->
    #btc_version{
        version=V,
        services=Services,
        timestamp=Timestamp,
        addr_recv=AddrRecv,
        addr_from=AddrFrom,
        nonce=Nonce,
        sub_version_num=SubVersionNum,
        start_height=StartHeight
    } = Version,
    BAddrRecv = encode_version_net_addr(AddrRecv),
    BAddrFrom = encode_version_net_addr(AddrFrom),
    BSubVersionNum = encode_var_str(SubVersionNum),
    <<
        V:32/little,
        Services:64/unsigned-little,
        Timestamp:64/little,
        BAddrRecv:26/binary,
        BAddrFrom:26/binary,
        Nonce:64/unsigned-little,
        BSubVersionNum/binary,
        StartHeight:32/little
    >>.

encode_command(Command) ->
    SCommand = atom_to_list(Command),
    binary:list_to_bin(SCommand ++ lists:duplicate(12 - length(SCommand), 0)).

encode_inv_vect(#btc_inv_vect{type = Type, hash = <<Hash:256/big>>}) ->
    EType = case Type of
        error -> 0;
        msg_tx -> 1;
        msg_block -> 2;
        _ when is_integer(Type) -> Type
    end,
    <<EType:32/unsigned-little, Hash:256/little>>.

encode_inv(#btc_inv{inventory=Inventory}) ->
    encode_var_list(Inventory, fun encode_inv_vect/1).

encode_getdata(#btc_getdata{inventory=Inventory}) ->
    encode_var_list(Inventory, fun encode_inv_vect/1).

encode_getblocks(#btc_getblocks{version = Version, block_locator_hashes = BlockLocatorHashes, hash_stop = <<HashStop:256/big>>}) ->
    BBlockLocatorHashes = encode_var_list_noskip(BlockLocatorHashes, fun encode_hash/1),
    <<Version:32/unsigned-little, BBlockLocatorHashes/binary, HashStop:256/little>>.

encode_getheaders(#btc_getheaders{version = Version, block_locator_hashes = BlockLocatorHashes, hash_stop = <<HashStop:256/big>>}) ->
    BBlockLocatorHashes = encode_var_list_noskip(BlockLocatorHashes, fun encode_hash/1),
    <<Version:32/unsigned-little, BBlockLocatorHashes/binary, HashStop:256/little>>.

encode_headers(#btc_headers{long_headers=LongHeaders}) ->
    encode_var_list(LongHeaders, fun encode_long_header/1).

%% Other %%

hash160_from_address(BTCAddress) ->
    try
        <<Network:8/unsigned, Hash160:20/bytes, Checksum:32/unsigned>> = base58:decode(BTCAddress),
        <<_:28/bytes, Checksum:32/unsigned-little>> = ecoinpool_hash:dsha256_hash(<<Network:8/unsigned, Hash160:20/bytes>>),
        Hash160
    catch error:_ ->
        error(invalid_bitcoin_address)
    end.

get_hash(#btc_block{header=Header}) ->
    get_hash(encode_main_header(Header));
get_hash(Header=#btc_header{}) ->
    get_hash(encode_main_header(Header));
get_hash(Tx=#btc_tx{}) ->
    get_hash(encode_tx(Tx));
get_hash(Bin) when is_binary(Bin) ->
    ecoinpool_hash:dsha256_hash(Bin).

verify_block_basic(#btc_block{header=Header, txns=Txns}) ->
    #btc_header{
        version=Version,
        hash_merkle_root=HashMerkleRoot,
        bits=Bits,
        auxpow=AuxPow
    } = Header,
    Target = ecoinpool_util:bits_to_target(Bits),
    Hash = get_hash(Header),
    TxnHashes = lists:map(fun get_hash/1, Txns),
    RealHashMerkleRoot = ecoinpool_hash:tree_dsha256_hash(TxnHashes),
    if
        AuxPow =:= undefined, Hash > Target ->
            {error, target};
        HashMerkleRoot =/= RealHashMerkleRoot ->
            {error, merkle_root};
        Version band 16#100 =:= 0, AuxPow =:= undefined ->
            {error, auxpow_not_allowed};
        AuxPow =/= undefined ->
            #btc_auxpow{
                coinbase_tx=CoinbaseTx,
                block_hash=BlockHash,
                tx_tree_branches=TxTreeBranches,
                parent_header=ParentHeader
            } = AuxPow,
            RealBlockHash = get_hash(ParentHeader),
            ParentHeaderMerkleRoot = ParentHeader#btc_header.hash_merkle_root,
            CoinbaseTxHash = get_hash(CoinbaseTx),
            RealParentHeaderMerkleRoot = ecoinpool_hash:fold_tree_branches_dsha256_hash(CoinbaseTxHash, TxTreeBranches),
            if
                RealBlockHash > Target ->
                    {error, auxpow_target};
                BlockHash =/= RealBlockHash ->
                    {error, auxpow_block_hash};
                ParentHeaderMerkleRoot =/= RealParentHeaderMerkleRoot ->
                    {error, auxpow_parent_merkle_root};
                true ->
                    [CoinbaseTxIn] = CoinbaseTx#btc_tx.tx_in,
                    case binary:match(CoinbaseTxIn#btc_tx_in.signature_script, Hash) of
                        nomatch ->
                            {error, auxpow_parent_coinbase};
                        _ ->
                            ok
                    end
            end;
        true ->
            ok
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
        hash_prev_block = base64:decode(<<"AAAAAAAABoA4txIh6l9HqvvVHzPGRp4izaHQq3mXSWo=">>),
        hash_merkle_root = base64:decode(<<"+QPHTGxLuwlkJSFywqJajBrtcwLuKoiHwRZolwfUIEc=">>),
        timestamp = 1321870454,
        bits = 437129626,
        nonce = 2684961857
    },
    [
        ?_assertEqual({DHeader, <<>>}, decode_header(EHeader)),
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

encode_auxpow_test_() ->
    EAuxPOW = base64:decode(<<"AQAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP////83BEttCxoDRbIAUiz6vm1t9PgsbckHZOle+WNcwqSrg4YrqhbT1iWOlPGlOFOQN0kBAAAAAAAAAP////8BWhNWKgEAAABDQQSKuGvFWJdPA1AObmrj/iAuKXxBMm3i0trgHhYTnFaawlsMBgC6+TJT/tGzwZKttrsZnPGrV140gzm0T1mSxwTPrAAAAAAn8KtiOt5HXpwN4tQEQmbmWxSuBmMGJ7G1IAAAAAAAAAX5sGhq0WwiZ8xTBoel7dwxqSCGNxb7vNhMJQ25IHqi3hysmwX/aJ/fZUAqEAaqOgT3jaG1e2Lq+ADAGw5IA2cW8tH7fHUYZPkos3eNfblB+CdOpVo/AcrNCe1KMyl0S45wnoGRrDIbjq1BnZOD+qlE6ukuDHZ7/XFXtiWpJoSkB4j4tkEOQaVNpJP90NoIqyIoCWZFZH+doHbK1C4mW/MuAAAAAAAAAAAAAQAAAEyrZVt1wzmfhMbzPXs2PSYpWQPh3PrtWdoBAAAAAAAAXWb6XgsqHvp1esikEjISO0HGWIJsAtxLrASDiRMmw/mubJlOS20LGmSgcoo=">>),
    AuxHash = binary_part(EAuxPOW, {57, 32}),
    DAuxPOW = #btc_auxpow{
        coinbase_tx = #btc_tx{
            tx_in = [
                #btc_tx_in{
                    prev_output_hash = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
                    prev_output_index = 16#ffffffff,
                    signature_script = encode_script([436956491, 45637, 2, <<250,190,109,109, AuxHash/binary, 1,0,0,0,0,0,0,0>>]),
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
        block_hash = base64:decode(<<"AAAAAAAAILWxJwZjBq4UW+ZmQgTU4g2cXkfeOmKr8Cc=">>),
        tx_tree_branches = [
            base64:decode(<<"3qJ6ILkNJUzYvPsWN4YgqTHc7aWHBlPMZyJs0WposPk=">>),
            base64:decode(<<"FmcDSA4bwAD46mJ7taGN9wQ6qgYQKkBl359o/wWbrBw=">>),
            base64:decode(<<"jkt0KTNK7QnNygE/WqVOJ/hBuX2Nd7Mo+WQYdXz70fI=">>),
            base64:decode(<<"B6SEJqkltldx/Xt2DC7p6kSp+oOTnUGtjhsyrJGBnnA=">>),
            base64:decode(<<"LvNbJi7UynagnX9kRWYJKCKrCNrQ/ZOkTaVBDkG2+Ig=">>)
        ],
        parent_header = #btc_header{
            hash_prev_block = base64:decode(<<"AAAAAAAAAdpZ7frc4QNZKSY9Nns988aEnznDdVtlq0w=">>),
            hash_merkle_root = base64:decode(<<"+cMmE4mDBKxL3AJsgljGQTsSMhKkyHp1+h4qC176Zl0=">>),
            timestamp = 1318677678,
            bits = 436956491,
            nonce = 2322767972
        }
    },
    [
        ?_assertEqual({DAuxPOW, <<>>}, decode_auxpow(EAuxPOW)),
        ?_assertEqual(EAuxPOW, encode_auxpow(DAuxPOW))
    ].

ip_test_() ->
    DataSet = [
        {{ip4, "192.168.42.1"}, <<0:16, 0:16, 0:16, 0:16, 0:16, 16#ffff:16, 192, 168, 42, 1>>},
        {{ip6, "::"}, <<0:16, 0:16, 0:16, 0:16, 0:16, 0:16, 0:16, 0:16>>},
        {{ip6, "1:0:1::"}, <<1:16, 0:16, 1:16, 0:16, 0:16, 0:16, 0:16, 0:16>>},
        {{ip6, "::1:0:1"}, <<0:16, 0:16, 0:16, 0:16, 0:16, 1:16, 0:16, 1:16>>},
        {{ip6, "2001:db8::1"}, <<16#2001:16, 16#0db8:16, 0:16, 0:16, 0:16, 0:16, 0:16, 16#0001:16>>},
        {{ip6, "2001:db8:0:1:1:1:1:1"}, <<16#2001:16, 16#0db8:16, 0:16, 1:16, 1:16, 1:16, 1:16, 1:16>>},
        {{ip6, "2001:0:0:1::1"}, <<16#2001:16, 0:16, 0:16, 1:16, 0:16, 0:16, 0:16, 1:16>>},
        {{ip6, "2001:db8::1:0:0:1"}, <<16#2001:16, 16#0db8:16, 0:16, 0:16, 1:16, 0:16, 0:16, 1:16>>}
    ],
    [?_assertEqual({D, <<>>}, decode_ip(E)) || {D, E} <- DataSet] ++
    [?_assertEqual(E, encode_ip(D)) || {D, E} <- DataSet].

net_addr_test_() ->
    EAddr1 = base64:decode(<<"4hUQTQEAAAAAAAAAAAAAAAAAAAAAAP//CgAAASCN">>),
    DAddr1 = #btc_net_addr{time=1292899810, services=1, ip={ip4, "10.0.0.1"}, port=8333},
    [
        ?_assertEqual({DAddr1, <<>>}, decode_net_addr(EAddr1)),
        ?_assertEqual(EAddr1, encode_net_addr(DAddr1))
    ].

version_test_() ->
    EVersion = base64:decode(<<"nHwAAAEAAAAAAAAA5hUQTQAAAAABAAAAAAAAAAAAAAAAAAAAAAD//woAAAEgjQEAAAAAAAAAAAAA\nAAAAAAAAAP//CgAAAiCN3Z0gLDq0VxMAVYEBAA==">>),
    DVersion = #btc_version{
        version = 31900,
        services = 1,
        timestamp = 1292899814,
        addr_recv = #btc_net_addr{services=1, ip={ip4, "10.0.0.1"}, port=8333},
        addr_from = #btc_net_addr{services=1, ip={ip4, "10.0.0.2"}, port=8333},
        nonce = 1393780771635895773,
        sub_version_num = <<>>,
        start_height = 98645
    },
    [
        ?_assertEqual({DVersion, <<>>}, decode_version(EVersion)),
        ?_assertEqual(EVersion, encode_version(DVersion))
    ].

command_test_() ->
    [
        ?_assertEqual(version, decode_command(<<"version",0,0,0,0,0>>)),
        ?_assertEqual(<<"version",0,0,0,0,0>>, encode_command(version))
    ].

inv_test_() ->
    EInv = base64:decode(<<"AQEAAAB0lIKueCpOhbzvAVsrHVsf1Agb/ryGu+dwLyoBwELThw==">>),
    DInv = #btc_inv{inventory=[#btc_inv_vect{type=msg_tx, hash=base64:decode(<<"h9NCwAEqL3Dnu4a8/hsI1B9bHStbAe+8hU4qeK6ClHQ=">>)}]},
    [
        ?_assertEqual({DInv, <<>>}, decode_inv(EInv)),
        ?_assertEqual(EInv, encode_inv(DInv))
    ].

-endif.
