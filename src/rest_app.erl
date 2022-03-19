%%%-------------------------------------------------------------------
%% @doc rest public API
%% @end
%%%-------------------------------------------------------------------

-module(rest_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, [ApiKey]) ->
    ets:new(variables, [set, protected, named_table]),
    ets:insert(variables, {api_key, ApiKey}),
    application:start(cowlib),
	application:start(ranch),
	application:start(cowboy),
    application:start(inets),
    application:start(ssl),
    application:start(gun),
    Dispatch = cowboy_router:compile([
        {"localhost", [
            {"/", cowboy_static, {priv_file, rest, "static/index.html"}},
            {"/data_endpoint", data_handler, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(my_http_listener,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ),
    rest_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
