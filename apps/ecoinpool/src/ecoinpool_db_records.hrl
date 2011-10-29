
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
    active_subpools :: [binary()]
}).

-record(subpool, {
    id :: binary(),
    name :: binary(),
    port :: integer(),
    pool_type :: atom(),
    coin_daemon_config :: [tuple()]
}).

-record(worker, {
    id :: binary(),
    user_id :: term(),
    sub_pool_id :: binary(),
    name :: binary(),
    pass :: binary() | atom()
}).
