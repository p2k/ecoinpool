
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

-module(ecoinpool_mysql_replicator_test_launch).
-export([start/0]).

start() ->
    ok = application:start(sasl),
    ok = application:start(crypto),
    ok = application:start(crypto),
    ok = application:start(public_key),
    ok = application:start(ibrowse),
    ok = application:start(couchbeam),
    ok = application:start(mysql),
    ok = application:start(ecoinpool_mysql_replicator).
