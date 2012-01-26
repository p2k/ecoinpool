
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

-record(configuration, {
    active_subpools :: [binary()],
    share_loggers :: [conf_property()]
}).
-type configuration() :: #configuration{}.

-record(auxpool, {
    name :: binary(),
    pool_type :: atom(),
    round :: integer() | undefined,
    aux_daemon_config :: [conf_property()]
}).
-type auxpool() :: #auxpool{}.

-record(subpool, {
    id :: binary(),
    name :: binary(),
    port :: integer(),
    pool_type :: atom(),
    max_cache_size = 0 :: integer(),
    max_work_age :: integer(),
    accept_workers :: registered | valid_address | any,
    lowercase_workers :: boolean(),
    ignore_passwords :: boolean(),
    round :: integer() | undefined,
    worker_share_subpools :: [binary()],
    coin_daemon_config :: [conf_property()],
    aux_pool :: auxpool() | undefined
}).
-type subpool() :: #subpool{}.

-record(worker, {
    id :: binary(),
    user_id = -1 :: term(),
    sub_pool_id :: binary(),
    name :: binary(),
    pass :: binary() | atom(),
    lp = true :: boolean(),
    lp_heartbeat = true :: boolean(),
    aux_lp = true :: boolean()
}).
-type worker() :: #worker{}.

-record(share, {
    timestamp :: erlang:timestamp(),
    server_id = local :: binary() | local,
    
    subpool_id :: binary(),
    subpool_name :: binary(),
    worker_id :: binary(),
    worker_name :: binary(),
    user_id :: term(),
    ip :: string(),
    user_agent :: string(),
    
    state :: invalid | valid | candidate,
    reject_reason :: reject_reason() | undefined,
    hash :: binary() | undefined,
    target :: binary() | undefined,
    block_num :: integer() | undefined,
    prev_block :: binary() | undefined,
    round :: integer() | undefined,
    data :: binary() | undefined,
    
    auxpool_name :: binary() | undefined,
    aux_state :: invalid | valid | candidate | undefined,
    aux_hash :: binary() | undefined,
    aux_target :: binary() | undefined,
    aux_block_num :: integer() | undefined,
    aux_prev_block :: binary() | undefined,
    aux_round :: integer() | undefined
}).
-type share() :: #share{}.
