
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

-record(btc_header, {
    version :: integer(),
    hash_prev_block :: binary(),
    hash_merkle_root :: binary(),
    timestamp :: integer(),
    bits :: integer(),
    nonce :: integer()
}).
-type btc_header() :: #btc_header{}.

-record(btc_tx_in, {
    prev_output_hash :: binary(),
    prev_output_index :: integer(),
    signature_script :: binary(),
    sequence :: integer()
}).
-type btc_tx_in() :: #btc_tx_in{}.

-record(btc_tx_out, {
    value :: integer(),
    pk_script :: binary()
}).
-type btc_tx_out() :: #btc_tx_out{}.

-record(btc_tx, {
    version :: integer(),
    tx_in :: [btc_tx_in()],
    tx_out :: [btc_tx_out()],
    lock_time :: integer()
}).
-type btc_tx() :: #btc_tx{}.

-record(btc_block, {
    header :: btc_header(),
    txns :: [btc_tx()]
}).
-type btc_block() :: #btc_block{}.
