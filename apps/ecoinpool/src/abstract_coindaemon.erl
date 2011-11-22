
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

% This abstract module acts as a wrapper for gen_coindaemon modules. As such, it
% allows easier handling of coindaemons within the server module.

% Instances of this module are returned by ecoinpool_server_sup:start_coindaemon/3

-module(abstract_coindaemon, [M, PID]).

-export([getwork_method/0, sendwork_method/0, share_target/0, encode_workunit/1, analyze_result/1, make_reply/1, post_workunit/0, send_result/1]).

-export([coindaemon_module/0]).

getwork_method() ->
    M:getwork_method().

sendwork_method() ->
    M:sendwork_method().

share_target() ->
    M:share_target().

encode_workunit(Workunit) ->
    M:encode_workunit(Workunit).

analyze_result(Result) ->
    M:analyze_result(Result).

make_reply(Items) ->
    M:make_reply(Items).

post_workunit() ->
    M:post_workunit(PID).

send_result(BData) ->
    M:send_result(PID, BData).

coindaemon_module() ->
    M.
