
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
    view_update_interval :: integer()
}).

-record(auxpool, {
    name :: binary(),
    pool_type :: atom(),
    round :: integer() | undefined,
    aux_daemon_config :: [tuple()]
}).

-record(subpool, {
    id :: binary(),
    name :: binary(),
    port :: integer(),
    pool_type :: atom(),
    max_cache_size = 0 :: integer(),
    max_work_age :: integer(),
    round :: integer() | undefined,
    worker_share_subpools :: [binary()],
    coin_daemon_config :: [tuple()],
    aux_pool :: #auxpool{} | undefined
}).

-record(worker, {
    id :: binary(),
    user_id :: term(),
    sub_pool_id :: binary(),
    name :: binary(),
    pass :: binary() | atom(),
    lp :: boolean(),
    lp_heartbeat :: boolean()
}).
