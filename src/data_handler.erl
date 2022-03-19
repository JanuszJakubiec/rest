-module(data_handler).

-behaviour(cowboy_handler).

-export([init/2, allowed_methods/2, content_types_accepted/2, from_json/2, from_text/2]).

-type match() :: #{binary() => binary() | integer() | {binary(), integer(), integer()} | no_weather}.

%-------------------------------------------%
%               rest_callbacks              %
%-------------------------------------------%
init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_accepted(Req, State) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, from_json},
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_text}
     ], Req, State}.

from_json(Req0, State) ->
    {ok, Data, _} = cowboy_req:read_body(Req0),
    ParsedData = jsone:decode(Data),
    process_request(ParsedData, Req0, State).

from_text(Req0, State) ->
    {ok, Data, _} = cowboy_req:read_body(Req0),
    List = uri_string:dissect_query(Data),
    ParsedData = lists:foldl(fun({Key, Value}, Acc) ->
        maps:put(Key, Value, Acc)
    end, #{}, List),
    process_request(ParsedData, Req0, State).

%------------------------------------------%
%               my_functions               %
%------------------------------------------%
-spec process_request(#{binary() => binary()}, cowboy_req:req(), any()) ->
    {true, cowboy_req:req(), any()}.
process_request(ParsedData, Req0, State) ->
    case get_league_id_and_current_year(ParsedData) of
        {error, Message} ->
            prepare_server_response(Message, Req0, State);
        {ok, LeagueId, CurrentYear} ->
            case get_next_matches(LeagueId, CurrentYear, ParsedData) of
                {error, Message} ->
                    prepare_server_response(Message, Req0, State);
                {ok, MatchesList} ->
                    MatchWeatherData = sort_matches(get_weather(MatchesList)),
                    prepare_server_response(generate_HTML(MatchWeatherData), Req0, State)
            end
    end.

-spec get_league_id_and_current_year(#{binary() => binary()}) ->
    {ok, integer(), integer()} | {error, binary()}.
get_league_id_and_current_year(ParsedData) ->
    case httpc:request(get,
         {uri_string:recompose(#{scheme => "https", host => "api-football-v1.p.rapidapi.com",
             path => "/v3/leagues", query =>
                 "name=" ++
                 binary_to_list(maps:get(<<"name">>,ParsedData, <<"Bundesliga 1">>)) ++
                 "&country=" ++
                 binary_to_list(maps:get(<<"country">>, ParsedData, <<"Germany">>))
             }),
         [{"x-rapidapi-host", "api-football-v1.p.rapidapi.com"},
          {"x-rapidapi-key", get_api_key()}
         ]}, [{ssl, [{verify, verify_none}]}], []) of
        {ok, {{_, 200, _}, _, LeagueResponse}} ->
            get_league_id_and_current_year_from_response(decode_list(LeagueResponse));
        _ ->
            {error, <<"<html><body><h1>Serwer nie był w stanie uzyskać danych</h1></body></html>"/utf8>>}
    end.

-spec get_league_id_and_current_year_from_response(#{binary() => any()}) ->
    {ok, integer(), integer()} | {error, binary()}.
get_league_id_and_current_year_from_response(#{<<"response">> :=
                                               [#{<<"league">> := League,
                                                  <<"seasons">> := Seasons}]}) ->
    LeagueId = maps:get(<<"id">>, League),
    case [Year || #{<<"current">> := Current, <<"year">> := Year} <- Seasons, Current] of
        [] ->
            {error, <<"<html><body><h1>Liga której szukasz, nie istnieje w bazie</h1></body></html>"/utf8>>};
        [CurrentYear] ->
            {ok, LeagueId, CurrentYear}
    end;
get_league_id_and_current_year_from_response(_) ->
    {error, <<"<html><body><h1>Liga której szukasz, nie istnieje w bazie</h1></body></html>"/utf8>>}.

-spec get_next_matches(integer(), integer(), #{binary() => binary()}) ->
    {ok, [#{atom() => binary() | integer()}]} | {error, binary()}.
get_next_matches(LeagueId, CurrentYear, ParsedData) ->
    MatchesN = maps:get(<<"matches_n">>, ParsedData, <<"9">>),
    case httpc:request(get,
         {uri_string:recompose(#{scheme => "https", host => "api-football-v1.p.rapidapi.com",
             path => "/v3/fixtures", query =>
                 "league=" ++ integer_to_list(LeagueId) ++
                 "&season=" ++ integer_to_list(CurrentYear) ++
                 "&next=" ++ binary_to_list(MatchesN)
             }),
         [{"x-rapidapi-host", "api-football-v1.p.rapidapi.com"},
          {"x-rapidapi-key", get_api_key()}
         ]}, [{ssl, [{verify, verify_none}]}], []) of
        {ok, {{_, 200, _}, _, FixturesResponse}} ->
            get_list_of_matches(maps:get(<<"response">>, decode_list(FixturesResponse)));
        _ ->
            {error, <<"<html><body><h1>Nie udało się uzyskać meczy</h1></body></html>"/utf8>>}
    end.

-spec get_list_of_matches(nil() | [#{binary() => any()}]) ->
    {ok, [#{atom() => binary() | integer()}]} | {error, binary()}.
get_list_of_matches([]) ->
    {error, <<"<html><body><h1>Nie udało się uzyskać meczy</h1></body></html>"/utf8>>};
get_list_of_matches(MatchesList) ->
    ProcessedList = lists:foldl(fun(
        #{<<"fixture">> := #{<<"timestamp">> := Timestamp, <<"venue">> := Venue},
          <<"teams">> := #{<<"away">> := AwayTeam, <<"home">> := HomeTeam}}, Acc) ->
            Acc ++ [#{timestamp => Timestamp,
                      city => maps:get(<<"city">>, Venue),
                      away_logo => maps:get(<<"logo">>, AwayTeam),
                      home_logo => maps:get(<<"logo">>, HomeTeam),
                      away_name => maps:get(<<"name">>, AwayTeam),
                      home_name => maps:get(<<"name">>, HomeTeam)}]
        end, [], MatchesList),
    {ok, ProcessedList}.

-spec prepare_server_response(binary(), cowboy_req:req(), any()) ->
    {true, cowboy_req:req(), any()}.
prepare_server_response(Body, Req0, State) ->
    Req1 = cowboy_req:set_resp_header(<<"content-type">>, <<"text/html">>, Req0),
    Req = cowboy_req:set_resp_body(Body, Req1),
    {true, Req, State}.

-spec get_weather([#{binary() => binary() | integer()}]) -> [match()].
get_weather(MatchesList) ->
    RequestsMap = lists:foldl(fun(Data = #{city := City}, Acc) ->
        {ok, RequestId} = httpc:request(get,
            {uri_string:recompose(#{scheme => "https", host => "yahoo-weather5.p.rapidapi.com",
                path => "/weather", query =>
                    "location=" ++ unicode:characters_to_list(City) ++ "&u=c"
                }),
            [{"x-rapidapi-host", "yahoo-weather5.p.rapidapi.com"},
             {"x-rapidapi-key", get_api_key()}
            ]}, [{ssl, [{verify, verify_none}]}], [{sync, false}]),
        maps:put(RequestId, Data, Acc)
    end, #{}, MatchesList),
    receive_responses(RequestsMap, length(MatchesList), []).

-spec receive_responses(#{httpc:request_id() => match()}, integer(), [match()]) -> [match()].
receive_responses(_, 0, Acc) ->
    Acc;
receive_responses(RequestMap, N, Acc) ->
    receive
        {http, {RequestId, {{_, 200, _}, _, Result}}} ->
            {NewAcc, NewRequestMap} = updateAcc(RequestMap, Acc, RequestId, Result),
            receive_responses(NewRequestMap, N-1, NewAcc);
        {http, {RequestId, _, _}} ->
            {NewAcc, NewRequestMap} = updateAcc(RequestMap, Acc, RequestId, none),
            receive_responses(NewRequestMap, N-1, NewAcc)
    after 3000 ->
        NewAcc = process_left_matches(RequestMap, Acc),
        receive_responses(RequestMap, 0, NewAcc)
    end.

-spec process_left_matches(#{httpc:request_id() => match()}, [match()]) -> [match()].
process_left_matches(RequestMap, Acc) ->
    lists:foldl(fun({_, InnerMap}, List) ->
        List ++ [InnerMap]
    end, Acc, maps:to_list(RequestMap)).

-spec updateAcc(#{httpc:request_id() => match()}, [match()], httpc:request_id(), none | binary()) ->
    {[match()], #{httpc:request_id() => match()}}.
updateAcc(RequestMap, Acc, RequestId, none) ->
    InnerMap = maps:get(RequestId, RequestMap),
    ParsedResult = no_weather,
    {Acc ++ [maps:put(weather, ParsedResult, InnerMap)], maps:remove(RequestId, RequestMap)};
updateAcc(RequestMap, Acc, RequestId, Result) ->
    InnerMap = maps:get(RequestId, RequestMap),
    ParsedResult = get_single_forecast(InnerMap, jsone:decode(Result)),
    {Acc ++ [maps:put(weather, ParsedResult, InnerMap)], maps:remove(RequestId, RequestMap)}.

-spec get_single_forecast(match(), #{binary() => any()}) ->
    no_weather | {binary(), integer(), integer()}.
get_single_forecast(Map, #{<<"forecasts">> := Forecasts}) ->
    MatchTimestamp = maps:get(timestamp, Map),
    case [{Weather, TemperatureLow, TemperatureHigh} ||
              #{<<"date">> := Timestamp, <<"text">> := Weather,
                <<"low">> := TemperatureLow, <<"high">> := TemperatureHigh} <- Forecasts,
              Timestamp < MatchTimestamp, Timestamp + 24*3600 > MatchTimestamp
         ] of
        [] ->
            no_weather;
        [Data] ->
            Data
    end;
get_single_forecast(_, _) ->
    no_weather.

-spec generate_HTML([match()]) -> binary().
generate_HTML(MatchList) ->
    MatchDivs = lists:foldl(fun(MatchData, Acc) ->
        HomeLogo = maps:get(home_logo, MatchData),
        HomeName = maps:get(home_name, MatchData),
        AwayLogo = maps:get(away_logo, MatchData),
        AwayName = maps:get(away_name, MatchData),
        CityName = maps:get(city, MatchData),
        Weather = maps:get(weather, MatchData, no_weather),
        FormattedDate = date_to_binary(maps:get(timestamp, MatchData)),

        OpenDiv = <<"<div class=\"match\">">>,
        HomeTeam = <<<<"<img src=\"">>/binary, HomeLogo/binary,
                     <<"\" style=\"width:100px;height:100px;\">">>/binary, HomeName/binary
                   >>,
        Separator = <<" : ">>,
        AwayTeam = <<AwayName/binary, <<"<img src=\"">>/binary, AwayLogo/binary,
                     <<"\" style=\"width:100px;height:100px;\">">>/binary
                   >>,
        DateAndPlace = <<FormattedDate/binary, <<" ">>/binary, CityName/binary>>,
        FormattedWeather = format_weather(Weather),
        CloseDiv = <<"</div>">>,
        <<Acc/binary, OpenDiv/binary, <<"<div class=\"teams\">">>/binary,
          HomeTeam/binary, Separator/binary, AwayTeam/binary, <<"</div><div>">>/binary,
          DateAndPlace/binary, <<"</div><div>">>/binary, FormattedWeather/binary,
          <<"</div>">>/binary, CloseDiv/binary, <<"<hr>">>/binary
        >>
    end, <<>>, MatchList),
    <<<<"<html><head><meta charset=\"ISO-8859-1\"><style>hr{width: 50%;}">>/binary,
      <<"body{text-align:center;} .teams{width:100%;}</style></head><body>">>/binary,
      MatchDivs/binary, <<"</body></html>">>/binary
    >>.

-spec date_to_binary(integer()) -> binary().
date_to_binary(Date) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:gregorian_seconds_to_datetime(Date + 24*3600),
    StringDate = integer_to_list(Day) ++ "/" ++ integer_to_list(Month) ++ "/" ++ integer_to_list(1970+Year),
    StringHour = integer_to_list(Hour+1) ++ ":" ++ integer_to_list(Minute) ++ ":" ++ integer_to_list(Second),
    list_to_binary(StringDate ++ " " ++ StringHour).

-spec format_weather({binary(), integer(), integer()}) -> binary().
format_weather({Conditions, LowTemperature, HighTemperature}) ->
    TLowBin = list_to_binary(integer_to_list(LowTemperature)),
    THighBin = list_to_binary(integer_to_list(HighTemperature)),
    <<Conditions/binary, <<" od: ">>/binary, TLowBin/binary,
      <<" do: ">>/binary, THighBin/binary, <<" stopni">>/binary
    >>;
format_weather(no_weather) ->
    <<"Brak dostępnych danych pogodowych">>.

-spec sort_matches([match()]) -> [match()].
sort_matches(MatchList) ->
    lists:sort(fun sort_function/2, MatchList).

-spec sort_function(match(), match()) -> boolean().
sort_function(#{timestamp := FirstTimestamp},
              #{timestamp := SecondTimestamp}) when FirstTimestamp =< SecondTimestamp ->
    true;
sort_function(_, _) ->
    false.

-spec get_api_key() -> string().
get_api_key() ->
    [{api_key, ApiKey}] = ets:lookup(variables, api_key),
    ApiKey.

-spec decode_list(string()) -> binary().
decode_list(String) ->
    jsone:decode(list_to_binary(String)).
