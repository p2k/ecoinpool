
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

-module(ecoinpool_jsonrpc).

-export([process_request/3, respond_success/5, respond_success/6, respond_error/5, respond_start_chunked/4, respond_finish_chunked/4]).

process_request(Req, ServerName, CheckAccept) ->
    Auth = case Req:get_header_value("Authorization") of
        "Basic " ++ BasicAuth ->
            try
                case binary:split(base64:decode(BasicAuth), <<":">>) of
                    [User, Pass] -> {User, Pass};
                    _ -> unauthorized
                end
            catch
                error:_ ->
                    unauthorized
            end;
        _ ->
            unauthorized
    end,
    AcceptsJSON = case CheckAccept of
        true ->
            Req:accepts_content_type("application/json");
        _ ->
            true
    end,
    case AcceptsJSON of
        true ->
            case Req:get(method) of
                'GET' ->
                    process_get(Req, Auth, ServerName);
                'POST' ->
                    process_post(Req, Auth, ServerName);
                _ ->
                    Req:respond({501, [{"Server", ServerName}, {"Content-Type", "text/plain"}], "Unknown method"}),
                    {error, unknown_http_method}
            end;
        false ->
            Req:respond({406, [{"Server", ServerName}, {"Content-Type", "text/plain"}], "For this service you must accept application/json."}),
            {error, not_accepted}
    end.

compose_error(Type, ReqId, JSONP) ->
    {HTTPCode, RPCCode, RPCMessage} = case Type of
        parse_error -> {500, -32700, <<"Parse error">>};
        invalid_request -> {400, -32600, <<"Invalid request">>};
        method_not_found -> {404, -32601, <<"Method not found">>};
        invalid_method_params -> {400, -32602, <<"Invalid parameters">>};
        authorization_required -> {401, -32001, <<"Authorization required">>};
        permission_denied -> {403, -32002, <<"Permission denied">>};
        {CustomCode, CustomMessage} when is_integer(CustomCode) ->
            BinCustomMessage = if
                is_binary(CustomMessage) -> CustomMessage;
                is_list(CustomMessage) -> list_to_binary(CustomMessage);
                true -> iolist_to_binary(io_lib:print(CustomMessage))
            end,
            {500, CustomCode, BinCustomMessage};
        _ -> {500, -32603, <<"Internal error">>}
    end,
    Body = ejson:encode(
        {[
            {<<"result">>, null},
            {<<"error">>, {[
                {<<"code">>, RPCCode},
                {<<"message">>, RPCMessage}
            ]}},
            {<<"id">>, ReqId}
        ]}
    ),
    case JSONP of
        undefined -> {HTTPCode, Body};
        Callback -> {HTTPCode, <<Callback/binary, $(, Body/binary, $), $;>>}
    end.

compose_success(Result, ReqId, JSONP) ->
    Body = ejson:encode(
        {[
            {<<"result">>, Result},
            {<<"error">>, null},
            {<<"id">>, ReqId}
        ]}
    ),
    case JSONP of
        undefined -> Body;
        Callback -> <<Callback/binary, $(, Body/binary, $), $;>>
    end.

process_get(Req, Auth, ServerName) ->
    try
        Properties = Req:parse_qs(),
        process_form_request(Auth, Properties)
    catch error:_ ->
        respond_error(Req, parse_error, ServerName)
    end.

process_post(Req, Auth, ServerName) ->
    case Req:get_header_value("Content-Type") of
        Type when Type =:= "application/json"; Type =:= undefined ->
            try
                case ejson:decode(Req:recv_body()) of % Decode JSON
                    {Properties} ->
                        ReqId = proplists:get_value(<<"id">>, Properties, 1),
                        case proplists:get_value(<<"method">>, Properties) of
                            Method when is_binary(Method) ->
                                case proplists:get_value(<<"params">>, Properties, []) of
                                    Params when is_list(Params) ->
                                        {ok, Method, Params, ReqId, Auth, undefined};
                                    _ ->
                                        respond_error(Req, invalid_request, ReqId, ServerName)
                                end;
                            _ ->
                                respond_error(Req, invalid_request, ReqId, ServerName)
                        end;
                    _ ->
                        respond_error(Req, invalid_request, ServerName)
                end
            catch _:_ ->
                respond_error(Req, parse_error, ServerName)
            end;
        "application/x-www-form-urlencoded" ->
            try
                Properties = Req:parse_post(),
                process_form_request(Auth, Properties)
            catch error:_ ->
                respond_error(Req, parse_error, ServerName)
            end;
        _ ->
            Req:respond({415, [{"Content-Type", "text/plain"}], "Unsupported Content-Type. We only accept application/json and application/x-www-form-urlencoded."}),
            {error, unsupported_content_type}
    end.

process_form_request(Auth, Properties) ->
    % Check for JSONP
    JSONP = case proplists:get_value("callback", Properties) of
        undefined -> undefined;
        Callback -> list_to_binary(Callback)
    end,
    Method = list_to_binary(proplists:get_value("method", Properties, "")),
    Params = lists:map(fun list_to_binary/1, proplists:get_all_values("params[]", Properties)),
    SReqId = proplists:get_value("id", Properties, "1"),
    ReqId = try % If possible convert to integer else convert to binary
        list_to_integer(SReqId)
    catch
        error:_ -> list_to_binary(SReqId)
    end,
    {ok, Method, Params, ReqId, Auth, JSONP}.

-spec make_headers(ServerName :: string(), JSONP :: undefined | binary()) -> list().
make_headers(ServerName, undefined) ->
    [{"Server", ServerName}, {"Content-Type", "application/json"}];
make_headers(ServerName, _) ->
    [{"Server", ServerName}, {"Content-Type", "text/javascript"}, {"Access-Control-Allow-Origin", "*"}].

respond_error(Req, Type, ServerName) ->
    respond_error(Req, Type, 1, ServerName, undefined).

respond_error(Req, Type, ReqId, ServerName) ->
    respond_error(Req, Type, ReqId, ServerName, undefined).

respond_error(Req, Type, ReqId, ServerName, JSONP) ->
    {HTTPCode, Body} = compose_error(Type, ReqId, JSONP),
    Headers = make_headers(ServerName, JSONP),
    case HTTPCode of
        401 -> Req:respond({HTTPCode, [{"WWW-Authenticate", "Basic realm=\"mining\""} | Headers], Body});
        _ -> Req:respond({HTTPCode, Headers, Body})
    end,
    {error, Type}.

respond_success(Req, Result, ReqId, ServerName, JSONP) ->
    respond_success(Req, Result, ReqId, ServerName, JSONP, []).

respond_success(Req, Result, ReqId, ServerName, JSONP, AdditionalHeaders) ->
    Body = compose_success(Result, ReqId, JSONP),
    Headers = make_headers(ServerName, JSONP),
    Req:respond({200, Headers ++ AdditionalHeaders, Body}).

respond_start_chunked(Req, ServerName, JSONP, AdditionalHeaders) ->
    Headers = make_headers(ServerName, JSONP),
    Req:respond({200, Headers ++ AdditionalHeaders, chunked}).

respond_finish_chunked(Resp, Result, ReqId, JSONP) ->
    Body = case Result of
        {error, Type} ->
            element(2, compose_error(Type, ReqId, JSONP));
        _ ->
            compose_success(Result, ReqId, JSONP)
    end,
    Resp:write_chunk(Body),
    Resp:write_chunk(<<>>).
