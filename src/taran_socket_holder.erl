-module(taran_socket_holder).
-behaviour(gen_server).

-export([start_link/1, handle_info/2, code_change/3, terminate/2]).
-export([init/1, handle_call/3, handle_cast/2, code_reload/0]).

-export([req/3, req/4]).


-define(IPROTO_CODE,          16#00).
-define(REQUEST_CODE_SELECT,  16#01).

-define(IPROTO_SYNC,          16#01).
-define(REQUEST_SYNC_TRUE,    16#01).
-define(REQUEST_SYNC_FALSE,   16#00).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% OTP gen_server api
start_link(Args) -> gen_server:start_link(?MODULE, Args, []).

init(Args) -> init_(Args).
handle_info(Message, State) -> info_(State, Message).
code_reload() -> code_change([], #{}, []).
code_change(_OldVersion, State, _Extra) -> {ok, State}.
terminate(_Reason, _State) -> ok.

%%casts
handle_cast({run, _FunName, Fun, Args}, State) -> apply(Fun, [State|Args]);
handle_cast(_Req, State) -> cast_unknown(State).
%%calls
handle_call({run, _FunName, Fun, Args}, From, State) -> apply(Fun, [State,From|Args]);
handle_call(_Req, _From, State) -> call_unknown(State).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-define(S, #{
  s     => undefined,
  stime => erlang:system_time(seconds),
  args  => undefined,
  refs  => [],  %% ordset [{Until, NewSeq, Ref, Pid, Code}]
  buf   => <<>>, 
  seq   => 1}).


-define(SOCKET_TTL,     600).    %% Secs
-define(SOCKET_MAX_REQ, 600000). %% Secs



%% Args = connect Options
init_(Args) ->
  TcpOpts = [
              {mode, binary}
             ,{packet, raw}
             ,{active, false}
             ,{exit_on_close, true}
             %,{backlog, 32}
             %,{delay_send, Mode =/= blocked},
             ,{keepalive, true}
            ],
  ConnArgs = Args#{tcp_opts => TcpOpts},
  case connect(ConnArgs) of
    {ok, Socket}           -> {ok, ?S#{s => Socket, args := ConnArgs}};
    {err, {timeout, Desc}} -> {stop, {shutdown, {timeout, Desc}}};
    Else ->
      timer:sleep(1000), %% sleep for slowdown restarts
      {stop, {shutdown, Else}}
  end.

connect(_Args = #{host := Host, port := Port, user := User,
                  pass := Pass, tcp_opts := TcpOpts, connect_timeout := ConnectTimeout}) ->
  case gen_tcp:connect(Host, Port, TcpOpts, ConnectTimeout) of
    {ok, Socket} ->
      {ok, GreetingData} = gen_tcp:recv(Socket, 0),
      case User == <<"none">> andalso Pass == <<"none">> of
        true -> 
          {ok, Socket};
        false ->
          case auth(Socket, User, Pass, GreetingData) of
            ok -> {ok, Socket};
            Else -> Else
          end
      end;
    {error, timeout} -> {err, {timeout, tarantool_socket_connect_timeout}};
    Else -> Else
  end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% AUTH
%% construct and send auth request and receive and parse response.
-define(IPROTO_LOGIN,  16#23).
-define(IPROTO_CRED,   16#21).
auth(Socket, Login, Password, Greeting) when is_binary(Login), is_binary(Password) ->

  Header = msgpack:pack(#{
    ?IPROTO_CODE => 16#07,
    ?IPROTO_SYNC => 16#00
  }),

  Scrample = scramble(Greeting, Password),

  Body = msgpack:pack(#{
    ?IPROTO_LOGIN => Login,
    ?IPROTO_CRED  => [<<"chap-sha1">>, Scrample]
  }),

  Len = msgpack:pack(erlang:size(Body) + erlang:size(Header)),
  Packet = <<Len/binary, Header/binary, Body/binary>>,
  gen_tcp:send(Socket, Packet),
  {ok, AuthResponse} = gen_tcp:recv(Socket, 0),

        UnpackFun =
          fun
            (Bin, AnswerAcc, F) when Bin /= <<>> ->
              case msgpack:unpack_stream(Bin, [{unpack_str, as_binary}]) of
                {Term,  RestBin} when Term /= error -> F(RestBin, [Term|AnswerAcc], F);
                {error, Reason} -> throw(Reason)
              end;
            (<<>>, AnswerAcc, _F) -> lists:reverse(AnswerAcc)
          end,
  AuthRes =
        case UnpackFun(AuthResponse, [], UnpackFun) of 
          [_,#{0 := 0,1 := 0},#{}]    -> ok;
          [_,#{0 := _,1 := _}, Else]  -> {err, Else};
          _ -> {err, auth_err}
        end,
  AuthRes;

auth(Socket, Login, Password, Greeting) when is_list(Login) ->
  auth(Socket, list_to_binary(Login), Password, Greeting);
auth(Socket, Login, Password, Greeting) when is_list(Password) ->
  auth(Socket, Login, list_to_binary(Password), Greeting).


scramble(<<_Greeting:64/binary, GreetingSalt:44/binary, _Rest/binary>>, Password) ->
  % http://tarantool.org/doc/dev_guide/box-protocol.html#iproto-protocol
  Salt      = binary:part(base64:decode(GreetingSalt), 0, 20),
  Hash1     = crypto:hash(sha, Password),
  Hash2     = crypto:hash(sha, Hash1),

  Context1  = crypto:hash_init(sha),
  Context2  = crypto:hash_update(Context1, Salt),
  Context3  = crypto:hash_update(Context2, Hash2),
  Scramble1 = crypto:hash_final(Context3), 

  Scramble  = crypto:exor(Hash1, Scramble1),

  Scramble.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% REQUEST
req(Pid, Req, Async) ->
  req(Pid, Req, Async, 5000).
req(Pid, Req, Async, Timeout) ->
  Ref = erlang:make_ref(),
  gen_server:cast(Pid, {run, req_, fun req_/6, [Ref, Req, self(), Async, Timeout]}),
  case Async of
    false ->
      receive
        {taran_socket_answer, Ref, Answer} -> Answer
      after
        Timeout+200 -> {err, {timeout, request_timeout}}
      end;
    true ->
      ok
  end.

req_(State = #{s := Socket, refs := Refs, seq := Seq}, Ref, Req, Pid, Async, Timeout) ->
  #{code := Code, body := Body} = Req,
  NewSeq = case Seq > 100000000 of true -> 1; false -> Seq + 1 end,
  NewState = State#{seq := NewSeq},

  HeaderMap = #{
    ?IPROTO_CODE    => Code, %% Example Select
    ?IPROTO_SYNC    => NewSeq},
  Header = msgpack:pack(HeaderMap),

  ReqLen = msgpack:pack(erlang:size(Header) + erlang:size(Body)),

  Packet = <<ReqLen/binary, Header/binary, Body/binary>>,

  gen_tcp:send(Socket, Packet),

  case Async of
    false ->
      {ok, RPacket} = gen_tcp:recv(Socket, 0),
      recv_(NewState, {tcp, Socket, RPacket});
    true -> ok
  end,

  {noreply, NewState}.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% process info messages, timeouts of soket signals and data received 
info_(State, {tcp,        Socket, Response}) -> recv_(State,  {tcp, Socket, Response});
info_(State, {tcp_closed, Socket})           -> {stop, {shutdown, tcp_closed}, State};
info_(State, {tcp_error,  Socket, Reason})   -> {stop, {shutdown, {tcp_error, Reason}}, State};
info_(State, timeout)                        -> timeout_(State);
info_(State, _)                              -> info_unknown(State).


timeout_(State) ->
  timeout_(State, erlang:system_time(millisecond)).
%
timeout_(State = #{refs := [{LastUntil,_,_,_,_}|_]}, Now) when LastUntil > Now -> 
  {noreply, State, LastUntil - Now};
%
timeout_(State = #{refs := [{LastUntil,_,_,_,_}|Refs]}, Now) when LastUntil =< Now -> 
  timeout_(State#{refs := Refs}, Now);
%
timeout_(State = #{refs := []}, _Now) ->
  {noreply, State}.



info_unknown(State = #{refs := Refs}) ->
  % print msg
  case Refs of
    [{LastUntil,_,_,_,_}|_] -> 
      Now = erlang:system_time(millisecond),
      HolderTimeout = case LastUntil - Now of V when V >= 0 -> V; _ -> 0 end,
      {noreply, State, HolderTimeout};
    [] ->
      {noreply, State}
  end.

cast_unknown(State = #{refs := Refs}) ->
  % print msg
  case Refs of
    [{LastUntil,_,_,_,_}|_] ->
      Now = erlang:system_time(millisecond),
      HolderTimeout = case LastUntil - Now of V when V >= 0 -> V; _ -> 0 end,
      {noreply, State, HolderTimeout};
    [] ->
      {noreply, State}
  end.

call_unknown(State = #{refs := Refs}) ->
  % print msg
  case Refs of
    [{LastUntil,_,_,_,_}|_] ->
      Now = erlang:system_time(millisecond),
      HolderTimeout = case LastUntil - Now of V when V >= 0 -> V; _ -> 0 end,
      {reply, {err, {call_error, unknown_msg}}, State, HolderTimeout};
    [] ->
      {reply, {err, {call_error, unknown_msg}}, State}
  end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% RECEIVE & UNPACK & ANSWER
recv_(State = #{buf := Buf, s := CurSocket}, {tcp, Socket, Packet}) when CurSocket == Socket ->
  {NewBuf, Answers} = parse_(<<Buf/binary, Packet/binary>>),
  NewState = #{refs := Refs} = resp_(State, Answers),
  {noreply, NewState#{buf := NewBuf}}.

parse_(BufPacket) ->
  {NewBuf, AnswerBins} = parse_(BufPacket, _AnswerAcc = []),
  UnpackFun =
    fun
      (Bin, AnswerAcc, F) when Bin /= <<>> ->
        case msgpack:unpack_stream(Bin, [{unpack_str, as_binary}]) of
          {Term,  RestBin} when Term /= error -> F(RestBin, [Term|AnswerAcc], F);
          {error, Reason} -> throw(Reason)
        end;
      (<<>>, AnswerAcc, _F) -> lists:reverse(AnswerAcc)
    end,
  Answers = [UnpackFun(AnswerBin, [], UnpackFun) || AnswerBin <- AnswerBins],
  {NewBuf, Answers}.


parse_(BufPacket, AnswerAcc) when BufPacket /= <<>> ->
  case erlang:size(BufPacket) < 5 of
    true ->
      {BufPacket, AnswerAcc};
    false ->
      case msgpack:unpack_stream(BufPacket, [{unpack_str, as_binary}]) of
        {Len, RestBin} when is_integer(Len) ->
          case RestBin of
            <<Bin:Len/binary>> ->
              %% Complite and Full
              parse_(<<>>, [Bin|AnswerAcc]);
            <<Bin:Len/binary, NewBuf/binary>> ->
              %% Complite and Part
              parse_(NewBuf, [Bin|AnswerAcc]);
            _IncompleteRest ->
              {BufPacket, AnswerAcc} %% TODO is in possible?
          end;
        {error, _Reason} ->
          throw({crap_received, BufPacket})
      end
  end;
parse_(<<>>, AnswerAcc) -> {<<>>, AnswerAcc}.


resp_(State = #{refs := Refs}, [[Header = #{0 := 0}, #{16#30 := AnswerBody}]|Answers]) ->
  #{?IPROTO_SYNC  := Seq} = Header,
  case lists:keytake(Seq, 2, Refs) of
    {value, {_Until, Seq, Ref, Pid, Code}, NewRefs} when Code == ?REQUEST_CODE_SELECT ->
      Pid ! {taran_socket_answer, Ref, {ok, AnswerBody}},
      resp_(State#{refs := NewRefs}, Answers);
    {value, {_Until, Seq, Ref, Pid, _ElseCode}, NewRefs} ->
      Answer =
        case AnswerBody of
          [Value]   -> Value;
          [[Value]] -> Value;
          Value     -> Value
        end,
      Pid ! {taran_socket_answer, Ref, {ok, Answer}},
      resp_(State#{refs := NewRefs}, Answers);
    false ->
      resp_(State, Answers)
  end;
%
resp_(State = #{refs := Refs}, [[Header = #{0 := 0}, _]|Answers]) ->
  #{?IPROTO_SYNC  := Seq} = Header,
  case lists:keytake(Seq, 2, Refs) of
    {value, {_Until, Seq, Ref, Pid, Code}, NewRefs} when Code == ?REQUEST_CODE_SELECT ->
      Pid ! {taran_socket_answer, Ref, {ok, []}},
      resp_(State#{refs := NewRefs}, Answers);
    {value, {_Until, Seq, Ref, Pid, _ElseCode}, NewRefs} ->
      Pid ! {taran_socket_answer, Ref, ok},
      resp_(State#{refs := NewRefs}, Answers);
    false ->
      %% dalaed answer? drop it, do_nothing
      resp_(State, Answers)
  end;
%
resp_(State = #{refs := Refs}, [[Header = #{0 := ErrCode}, #{16#31 := AnswerBody}]|Answers]) ->
  #{?IPROTO_SYNC  := Seq} = Header,
  case lists:keytake(Seq, 2, Refs) of
    {value, {_Until, Seq, Ref, Pid, _Code}, NewRefs} ->
       Pid ! {taran_socket_answer, Ref, {err, {ErrCode, AnswerBody}} },
       resp_(State#{refs := NewRefs}, Answers);
    false ->
      %% dalaed answer? drop it, do_nothing
      resp_(State, Answers)
  end;
%
resp_(State, []) ->
  State.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


