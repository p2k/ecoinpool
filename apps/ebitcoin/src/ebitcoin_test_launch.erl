
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

-module(ebitcoin_test_launch).
-export([start/0]).

start() ->
    ok = application:start(sasl),
    ok = application:start(crypto),
    ok = application:start(log4erl),
    ok = application:start(ibrowse),
    ok = application:start(couchbeam),
    ok = application:start(ebitcoin),
    ebitcoin_sup:start_client(bitcoin, "127.0.0.1", 8333).
