
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

-record(auxwork, {
    aux_hash :: binary(),
    target :: binary(),
    chain_id :: integer(),
    block_num :: integer(),
    prev_block :: binary() | undefined
}).
-type auxwork() :: #auxwork{}.

-record(workunit, {
    id :: binary(),
    ts :: erlang:timestamp(),
    target :: binary(),
    block_num :: integer(),
    prev_block :: binary(),
    data :: binary(),
    worker_id :: binary(),
    aux_work :: auxwork() | undefined,
    aux_work_stale = false :: boolean()
}).
-type workunit() :: #workunit{}.
