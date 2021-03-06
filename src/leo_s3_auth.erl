%%======================================================================
%%
%% Leo S3-Libs
%%
%% Copyright (c) 2012-2018 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% Leo Libs - Auth
%% @doc The authentication API for S3-API
%% @reference https://github.com/leo-project/leo_s3_libs/blob/master/src/leo_s3_auth.erl
%% @end
%%======================================================================
-module(leo_s3_auth).

-include("leo_s3_auth.hrl").
-include("leo_s3_endpoint.hrl").
-include("leo_s3_libs.hrl").
-include("leo_s3_user.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-export([start/2,
         create_table/2, put/1, bulk_put/1,
         update_providers/1,
         create_key/1, put_credential/3,
         get_credential/1, has_credential/1, has_credential/2,
         authenticate/3, get_signature/3,
         find_all/0, checksum/0
        ]).

-record(auth_params, {access_key_id = <<>> :: binary(),
                      secret_access_key = <<>> :: binary(),
                      signature = <<>> :: binary(),
                      sign_params = #sign_params{} :: #sign_params{},
                      sign_v4_params = #sign_v4_params{} :: #sign_v4_params{},
                      auth_info = #auth_info{} :: #auth_info{}
                     }).

-define(SUB_RESOURCES, [<<"acl">>,
                        <<"delete">>,
                        <<"lifecycle">>,
                        <<"location">>,
                        <<"logging">>,
                        <<"notification">>,
                        <<"partNumber">>,
                        <<"policy">>,
                        <<"requestPayment">>,
                        <<"torrent">>,
                        <<"uploadId">>,
                        <<"uploads">>,
                        <<"versionid">>,
                        <<"versioning">>,
                        <<"versions">>,
                        <<"website">>,
                        <<"response-content-type">>,
                        <<"response-content-language">>,
                        <<"response-expires">>,
                        <<"response-cache-control">>,
                        <<"response-content-disposition">>,
                        <<"response-content-encoding">>]).


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Launch or create  Mnesia/ETS
%%
-spec(start(Role, Providers) ->
             ok when Role::master | slave,
                     Providers::[atom()]).
start(slave, Providers) ->
    catch ets:new(?AUTH_TABLE, [named_table, set, public, {read_concurrency, true}]),
    catch ets:new(?AUTH_INFO,  [named_table, set, public, {read_concurrency, true}]),

    case Providers of
        [] ->
            void;
        _ ->
            ok = setup(ets, Providers)
    end,
    ok;
start(master, Providers) ->
    catch ets:new(?AUTH_INFO,  [named_table, set, public, {read_concurrency, true}]),
    ok = setup(mnesia, Providers),
    ok.


%% @doc update_providers(slave only)
%%
-spec(update_providers(Providers) ->
             ok when Providers::[atom()]).
update_providers(Providers) ->
    true = ets:insert(?AUTH_INFO, {1, #auth_info{db = ets,
                                                 provider = Providers}}),
    ok.


%% @doc Create credential table(mnesia)
%%
-spec(create_table(Mode, Nodes) ->
             ok when Mode::ram_copies|disc_copies,
                     Nodes::[atom()]).
create_table(Mode, Nodes) ->
    catch application:start(mnesia),
    {atomic, ok} =
        mnesia:create_table(
          ?AUTH_TABLE,
          [{Mode, Nodes},
           {type, set},
           {record_name, credential},
           {attributes, record_info(fields, credential)},
           {user_properties,
            [{access_key_id,     binary,  primary},
             {secret_access_key, binary,  false},
             {user_id,           binary,  false},
             {created_at,        integer, false}
            ]}
          ]),
    ok.


%% @doc Add a credential (an authentication)
%%
-spec(put(Credential) ->
             ok | {error, any()} when Credential::#credential{}).
put(#credential{access_key_id = Id} = Credential) ->
    DB_1 = case get_auth_info() of
               {ok, #auth_info{db = DB}} ->
                   DB;
               _ ->
                   mnesia
           end,
    leo_s3_libs_data_handler:insert(
      {DB_1, ?AUTH_TABLE}, {Id, Credential}).


%% @doc Add credentials
%%
-spec(bulk_put(CredentialList) ->
             ok when CredentialList::[#credential{}]).
bulk_put([]) ->
    ok;
bulk_put([Credential|Rest]) ->
    _ = ?MODULE:put(Credential),
    bulk_put(Rest).


%% @doc Generate access-key-id and secret-access-key
%%
-spec(create_key(UserId) ->
             {ok, [tuple()]} | {error, any()} when UserId::binary()).
create_key(UserId) ->
    case get_auth_info() of
        {ok, #auth_info{db = ets}} ->
            {error, not_generated};
        {ok, #auth_info{db = mnesia}} ->
            Clock    = integer_to_list(leo_date:clock()),
            ClockBin = list_to_binary(Clock),
            Digest0  = list_to_binary(string:sub_string(
                                        leo_hex:binary_to_hex(
                                          crypto:hash(sha, term_to_binary({UserId, Clock}))),1,20)),
            Digest1 = list_to_binary(leo_hex:binary_to_hex(
                                       crypto:hash(sha, << UserId/binary, "/", ClockBin/binary >> ))),
            create_key_1(UserId, Digest0, Digest1);
        not_found ->
            {error, not_initialized}
    end.


%% @doc Generate a credential
%% @private
-spec(create_key_1(UserId, Digest0, Digest1) ->
             {ok, [tuple()]} | {error, any()} when UserId::binary(),
                                                   Digest0::binary(),
                                                   Digest1::binary()).
create_key_1(UserId, Digest0, Digest1) ->
    case leo_s3_libs_data_handler:lookup({mnesia, ?AUTH_TABLE}, Digest0) of
        {ok, _} ->
            create_key(UserId);
        not_found ->
            _ = leo_s3_libs_data_handler:insert(
                  {mnesia, ?AUTH_TABLE}, {[], #credential{access_key_id     = Digest0,
                                                          secret_access_key = Digest1,
                                                          created_at        = leo_date:now()}}),
            {ok, [{access_key_id,     Digest0},
                  {secret_access_key, Digest1}]};
        _ ->
            {error, not_initialized}
    end.

%% @doc Put a credential
%%
-spec(put_credential(AccessKeyId, SecretAccessKey, CreatedAt) ->
            {ok, [tuple()]} | {error, any()} when AccessKeyId::binary(),
                                                  SecretAccessKey::binary(),
                                                  CreatedAt::integer()).
put_credential(AccessKeyId, SecretAccessKey, CreatedAt) ->
    case leo_s3_libs_data_handler:lookup({mnesia, ?AUTH_TABLE}, AccessKeyId) of
        {ok, _} ->
            {error, already_exists};
        not_found ->
            _ = leo_s3_libs_data_handler:insert(
                  {mnesia, ?AUTH_TABLE}, {[], #credential{access_key_id     = AccessKeyId,
                                                          secret_access_key = SecretAccessKey,
                                                          created_at        = CreatedAt}}),
            {ok, [{access_key_id,     AccessKeyId},
                  {secret_access_key, SecretAccessKey}]};
        _ ->
            {error, not_initialized}
    end.


%% @doc Retrieve a credential from internal-db
%%
-spec(get_credential(AccessKeyId) ->
             {ok, #credential{}} | not_found | {error, any()} when AccessKeyId::binary()).
get_credential(AccessKeyId) ->
    case leo_s3_libs_data_handler:lookup({mnesia, ?AUTH_TABLE}, AccessKeyId) of
        {ok, #credential{}} = Ret ->
            case leo_s3_user_credential:find_by_access_key_id(AccessKeyId) of
                {ok, #user_credential{user_id = UserId}} ->
                    case leo_s3_user:find_by_id(UserId) of
                        {ok, _} ->
                            Ret;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.


%% @doc Has a credential into the master-nodes?
%%
-spec(has_credential(AccessKeyId) ->
             boolean() when AccessKeyId::binary()).
has_credential(AccessKeyId) ->
    case get_credential(AccessKeyId) of
        {ok, _Credential} ->
            true;
        _ ->
            false
    end.

-spec(has_credential(MasterNodes, AccessKey) ->
             boolean() when MasterNodes::[atom()],
                            AccessKey::binary()).
has_credential(MasterNodes, AccessKey) ->
    Ret = lists:foldl(
            fun(Node, false) ->
                    RPCKey = rpc:async_call(Node, leo_s3_auth, has_credential, [AccessKey]),
                    case rpc:nb_yield(RPCKey, ?DEF_REQ_TIMEOUT) of
                        {value, true} ->
                            true;
                        _Error ->
                            false
                    end;
               (_,  true) ->
                    true
            end, false, MasterNodes),
    Ret.


%% @doc Authenticate
%%
-spec(authenticate(Authorization, SignParams, IsCreateBucketOp) ->
             {ok, AccessKeyId, {Signature, SignHead, SignKey}|undefined} |
             {error, Cause} when Authorization::binary(),
                                 SignParams::#sign_params{},
                                 IsCreateBucketOp::boolean(),
                                 AccessKeyId::binary(),
                                 Signature::binary(),
                                 SignHead::binary(),
                                 SignKey::binary(),
                                 Cause::any()).
authenticate(Authorization, #sign_params{sign_ver = SignVer} = SignParams, IsCreateBucketOp) ->
    {AccessKeyId, Signature, SignV4Params} =
        case SignVer of
            v4 ->
                [<<"AWS4", _Method/binary>>, Params] = binary:split(Authorization, <<" ">>),
                ParamList = binary:split(Params, <<",">>, [global]),
                SignV4Params2 = extract_v4_params(ParamList),
                [AccessKeyId2|_] = binary:split(SignV4Params2#sign_v4_params.credential, <<"/">>),
                Signature2 = SignV4Params2#sign_v4_params.signature,
                {AccessKeyId2, Signature2, SignV4Params2};
            _ ->
                [AccWithAWS,Signature2|_] = binary:split(Authorization, <<":">>),
                <<"AWS ", AccessKeyId2/binary>> = AccWithAWS,
                SignV4Params2 = #sign_v4_params{},
                {AccessKeyId2, Signature2, SignV4Params2}
        end,
    authenticate_1(AccessKeyId, Signature, SignParams, SignV4Params, IsCreateBucketOp).

%% @private
authenticate_1(AccessKeyId, Signature, #sign_params{bucket = <<>>} = SignParams,
               SignV4Params, _IsCreateBucketOp) ->
    authenticate_2(#auth_params{access_key_id = AccessKeyId,
                                signature = Signature,
                                sign_params = SignParams,
                                sign_v4_params = SignV4Params});
authenticate_1(AccessKeyId, Signature, #sign_params{bucket = Bucket} = SignParams,
               SignV4Params, IsCreateBucketOp) ->
    case {leo_s3_bucket:head(AccessKeyId, Bucket), IsCreateBucketOp} of
        {ok, false} ->
            authenticate_2(#auth_params{access_key_id = AccessKeyId,
                                        signature = Signature,
                                        sign_params = SignParams#sign_params{bucket = Bucket},
                                        sign_v4_params = SignV4Params});
        {ok, true} ->
            {error, already_yours};
        {not_found, false} ->
            {error, not_found};
        {not_found, true} ->
            authenticate_2(#auth_params{access_key_id = AccessKeyId,
                                        signature = Signature,
                                        sign_params = SignParams#sign_params{bucket = Bucket},
                                        sign_v4_params = SignV4Params});
        _Other ->
            {error, unmatch}
    end.

%% @private
-spec(authenticate_2(AuthParams) ->
             {ok, AccessKeyId, {Signature, SignHead, SignKey}|undefined} |
             {error, Cause} when AuthParams::#auth_params{},
                                 AccessKeyId::binary(),
                                 Signature::binary(),
                                 SignHead::binary(),
                                 SignKey::binary(),
                                 Cause::any()).
authenticate_2(AuthParams) ->
    case get_auth_info() of
        {ok, AuthInfo} ->
            authenticate_3(AuthParams#auth_params{auth_info = AuthInfo});
        _ ->
            {error, not_initialized}
    end.

%% @private
-spec(authenticate_3(AuthParams) ->
             {ok, AccessKeyId, {Signature, SignHead, SignKey}|undefined} |
             {error, Cause} when AuthParams::#auth_params{},
                                 AccessKeyId::binary(),
                                 Signature::binary(),
                                 SignHead::binary(),
                                 SignKey::binary(),
                                 Cause::any()).
authenticate_3(AuthParams) ->
    #auth_params{access_key_id = AccessKeyId,
                 auth_info     = #auth_info{db = DB}} = AuthParams,

    case leo_s3_libs_data_handler:lookup({DB, ?AUTH_TABLE}, AccessKeyId) of
        {ok, #credential{secret_access_key = SecretAccessKey}} ->
            authenticate_4(AuthParams#auth_params{secret_access_key = SecretAccessKey});
        not_found when DB == ets ->
            authenticate_5(AuthParams);
        {error, Cause} ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING}, {function, "authenticate_3/1"},
                                    {line, ?LINE}, {body, Cause}]),
            {error, unmatch}
    end.

%% @private
-spec(authenticate_4(AuthParams) ->
             {ok, AccessKeyId, {Signature, SignHead, SignKey}|undefined} |
             {error, Cause} when AuthParams::#auth_params{},
                                 AccessKeyId::binary(),
                                 Signature::binary(),
                                 SignHead::binary(),
                                 SignKey::binary(),
                                 Cause::any()).
authenticate_4(#auth_params{secret_access_key = SecretAccessKey,
                            access_key_id = AccessKeyId,
                            signature = Signature,
                            sign_params = SignParams,
                            sign_v4_params = SignV4Params
                           }) ->
    case get_signature(SecretAccessKey, SignParams, SignV4Params) of
        {Signature, _SignHead, _SignKey} = Ret ->
            {ok, AccessKeyId, Ret};
        {WrongSig, _, _} ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING}, {function, "authenticate_4/1"},
                                    {line, ?LINE}, {body, WrongSig}]),
            {error, unmatch}
    end.

%% @private
-spec(authenticate_5(AuthParams) ->
             {ok, AccessKeyId, {Signature, SignHead, SignKey}|undefined} |
             {error, Cause} when AuthParams::#auth_params{},
                                 AccessKeyId::binary(),
                                 Signature::binary(),
                                 SignHead::binary(),
                                 SignKey::binary(),
                                 Cause::any()).
authenticate_5(AuthParams) ->
    #auth_params{access_key_id = AccessKeyId,
                 auth_info = #auth_info{provider = Provider}} = AuthParams,
    %% Retrieve auth-info from a provider
    %%
    case lists:foldl(fun(Node, [] = Acc) ->
                             RPCKey = rpc:async_call(Node, leo_s3_auth, get_credential, [AccessKeyId]),
                             case rpc:nb_yield(RPCKey, ?DEF_REQ_TIMEOUT) of
                                 {value, {ok, Value}} ->
                                     Value;
                                 _ ->
                                     Acc
                             end;
                        (_Node, Acc) ->
                             Acc
                     end, [], Provider) of
        [] ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING}, {function, "authenticate_5/1"},
                                    {line, ?LINE}, {body, "get_credential rpc failed"}]),
            {error, unmatch};
        Credential ->
            _ = leo_s3_libs_data_handler:insert({ets, ?AUTH_TABLE},{AccessKeyId, Credential}),
            authenticate_4(
              AuthParams#auth_params{
                secret_access_key = Credential#credential.secret_access_key})
    end.


%% @doc Retrieve a signature
%% @private
-spec(get_signature(SecretAccessKey, SignParams, SignV4Params) ->
             {SignatureBin, BinToSignHead, SigningKey}
                 when SecretAccessKey::binary(),
                      SignParams::#sign_params{},
                      SignV4Params::#sign_v4_params{}|undefined,
                      SignatureBin::binary(),
                      BinToSignHead::binary(),
                      SigningKey::binary()).
get_signature(SecretAccessKey, #sign_params{sign_ver = Ver} = SignParams, SignV4Params) ->
    get_signature_1(Ver, SecretAccessKey, SignParams, SignV4Params).


%% @doc Get AWS signature for v2 or v4
%% @private
-spec(get_signature_1(AuthVer, SecretAccessKey, SignParams, SignV4Params) ->
             {SignatureBin, BinToSignHead, SigningKey}
                 when AuthVer::aws_sign_ver(),
                      SecretAccessKey::binary(),
                      SignParams::#sign_params{},
                      SignV4Params::#sign_v4_params{}|undefined,
                      SignatureBin::binary(),
                      BinToSignHead::binary(),
                      SigningKey::binary()).
get_signature_1(?AWS_SIGN_VER_4, SecretAccessKey, SignParams, SignV4Params) ->
    #sign_params{http_verb = HTTPVerb,
                 date = Date,
                 raw_uri = URI,
                 query_str = QueryStr,
                 headers = Headers} = SignParams,
    #sign_v4_params{credential = Credential,
                    signed_headers = SignedHeaders} = SignV4Params,
    Header_1 = auth_v4_headers(Headers, SignedHeaders),
    Hash_2 = case lists:keyfind(<<"x-amz-content-sha256">>, 1, Headers) of
                 false ->
                     <<"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>;
                 {_, Hash_1} ->
                     Hash_1
             end,
    QueryStr_1 = auth_v4_qs(QueryStr),
    Request_1 = <<HTTPVerb/binary,        "\n",
                  URI/binary,             "\n",
                  QueryStr_1/binary,      "\n",
                  Header_1/binary,        "\n",
                  SignedHeaders/binary,   "\n",
                  Hash_2/binary>>,

    RequestHash = crypto:hash(sha256, Request_1),
    Date_1 = auth_v4_date(Date, Headers),
    [_AWSAccessKeyId, Date_2, Region, Service, <<"aws4_request">>] = binary:split(Credential, <<"/">>, [global]),
    Scope = <<Date_2/binary, "/", Region/binary, "/", Service/binary, "/aws4_request">>,
    RequestBin = leo_hex:binary_to_hexbin(RequestHash),
    BinToSignHead = <<Date_1/binary, "\n",
                      Scope/binary,  "\n">>,
    BinToSign = <<"AWS4-HMAC-SHA256\n",
                  BinToSignHead/binary,
                  RequestBin/binary>>,

    DateKey = crypto:hmac(sha256, <<"AWS4", SecretAccessKey/binary>>, Date_2),
    DateRegionKey = crypto:hmac(sha256, DateKey, Region),
    DateRegionServiceKey = crypto:hmac(sha256, DateRegionKey, Service),
    SigningKey = crypto:hmac(sha256, DateRegionServiceKey, <<"aws4_request">>),
    Signature = crypto:hmac(sha256, SigningKey, BinToSign),
    SignatureBin = leo_hex:binary_to_hexbin(Signature),
    {SignatureBin, BinToSignHead, SigningKey};

get_signature_1(?AWS_SIGN_VER_2, SecretAccessKey, SignParams, _) ->
    #sign_params{http_verb     = HTTPVerb,
                 content_md5   = ETag,
                 content_type  = ContentType,
                 date          = Date,
                 bucket        = Bucket,
                 raw_uri       = URI,
                 requested_uri = RequestedURI,
                 query_str     = QueryStr,
                 amz_headers   = AmzHeaders
                } = SignParams,
    Date_1 = auth_date(Date, AmzHeaders),
    Sub_1 = auth_resources(AmzHeaders),
    Sub_2 = auth_sub_resources(QueryStr),
    Bucket1 = auth_bucket(URI, Bucket, QueryStr),
    URI_1 = auth_uri(Bucket, URI, RequestedURI),
    BinToSign = <<HTTPVerb/binary,    "\n",
                  ETag/binary,        "\n",
                  ContentType/binary, "\n",
                  Date_1/binary,       "\n",
                  Sub_1/binary, Bucket1/binary, URI_1/binary, Sub_2/binary>>,
    Context = crypto:hmac_init(sha, SecretAccessKey),
    Context_1 = crypto:hmac_update(Context, BinToSign),
    HMac = crypto:hmac_final(Context_1),
    Signature = base64:encode(HMac),
    {Signature, <<>>, <<>>}.


%% @doc Retrieve all records
-spec(find_all() ->
             {ok, list(#credential{})} | not_found | {error, any()}).
find_all() ->
    case leo_s3_libs_data_handler:all({mnesia, ?AUTH_TABLE}) of
        {ok, RetL} ->
            {ok, RetL};
        Error ->
            Error
    end.


%% @doc Retrieve checksum of the table
-spec(checksum() ->
             {ok, non_neg_integer()} | not_found | {error, any()}).
checksum() ->
    case find_all() of
        {ok, RetL} ->
            {ok, erlang:crc32(term_to_binary(RetL))};
        _Error ->
            {ok, -1}
    end.


%%--------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Setup
%% @private
-spec(setup(DB, Provider) ->
             ok when DB::ets|mnesia,
                     Provider::list()).
setup(DB, Provider) ->
    true = ets:insert(?AUTH_INFO, {1, #auth_info{db       = DB,
                                                 provider = Provider}}),
    ok.

%% @doc Extract Signature V4 Params to Record
%% @private
-spec(extract_v4_params(SignV4Params) ->
             #sign_v4_params{} when SignV4Params::[binary()]).
extract_v4_params(ParamList) ->
    extract_v4_params(ParamList, #sign_v4_params{}).

extract_v4_params([], #sign_v4_params{} = SignV4Params) ->
    SignV4Params;
extract_v4_params([Head|Rest], #sign_v4_params{} = SignV4Params) ->
    [Key2, Val2|_] = binary:split(Head, <<"=">>),
    Key = leo_hex:binary_trim(Key2),
    Val = leo_hex:binary_trim(Val2),

    SignV4Params2 =
        case Key of
            <<"Credential">> ->
                SignV4Params#sign_v4_params{credential = Val};
            <<"Signature">> ->
                SignV4Params#sign_v4_params{signature = Val};
            <<"SignedHeaders">> ->
                SignV4Params#sign_v4_params{signed_headers = Val};
            _ ->
                SignV4Params
        end,
    extract_v4_params(Rest, SignV4Params2).


%% @doc Retrieve db-type from ETS
%% @private
-spec(get_auth_info() ->
             {ok, #auth_info{}} | not_found).
get_auth_info() ->
    case catch ets:lookup(leo_s3_auth_info, 1) of
        [{_, AuthInfo}|_] ->
            {ok, AuthInfo};
        _ ->
            not_found
    end.

%% @doc Construct Canonical Headers
%% @private
auth_v4_headers(Headers, SignedHeaders) ->
    HeaderList = binary:split(SignedHeaders, <<";">>, [global]),
    auth_v4_headers(Headers, HeaderList, <<>>).

%% @private
auth_v4_headers(_Headers, [], Acc) ->
    Acc;
auth_v4_headers(Headers, [Head|Rest], Acc) ->
    Val = case lists:keyfind(Head, 1, Headers) of
              false ->
                  <<>>;
              {_, Bin} ->
                  leo_hex:binary_trim(Bin)
          end,
    auth_v4_headers(Headers, Rest, <<Acc/binary, Head/binary, ":", Val/binary, "\n">>).


%% @doc Consutrct Canonical Query String
%% @private
auth_v4_qs(QueryStr) ->
    List = cow_qs:parse_qs(QueryStr),
    lists:foldl(fun({Key, Val}, Acc) ->
                        KeyBin = cow_qs:urlencode(Key),
                        ValBin = case Val of
                                     true ->
                                         <<>>;
                                     _ ->
                                         cow_qs:urlencode(Val)
                                 end,
                        case Acc of
                            <<>> ->
                                <<KeyBin/binary, "=", ValBin/binary>>;
                            _ ->
                                <<Acc/binary, "&", KeyBin/binary, "=", ValBin/binary>>
                        end
                end, <<>>, List).


%% @doc Retrieve date V4
%% @private
-spec(auth_v4_date(Date, Headers) ->
             binary() when Date::binary(),
                           Headers::list()).
auth_v4_date(Date, Headers) ->
    case lists:keyfind(<<"x-amz-date">>, 1, Headers) of
        false ->
            Date;
        {<<"x-amz-date">>, Date_2} ->
            Date_2
    end.

%% @doc Retrieve date
%% @private
-spec(auth_date(Date, CannonocalizedResources) ->
             binary() when Date::binary(),
                           CannonocalizedResources::list()).
auth_date(Date, CannonocalizedResources) ->
    case lists:keysearch("x-amz-date", 1, CannonocalizedResources) of
        {value, _} ->
            <<>>;
        false ->
            << Date/binary >>
    end.


%% @doc Retrieve a bucket from string
%% @private
%% auth_bucket("/",_Bucket, []) -> [];
%% auth_bucket(<<"/">>, Bucket,  _) -> << <<"/">>, Bucket >>;
-spec(auth_bucket(URI, Bucket, QueryStr) ->
             binary() when URI::binary(),
                           Bucket::binary(),
                           QueryStr::binary()).
auth_bucket(_, <<>>,  _) -> <<>>;
auth_bucket(_, Bucket,_) -> << <<"/">>/binary, Bucket/binary >>.


%% @doc Retrieve URI
%% @private
%%
%% AWS-S3 spec have two kind of path styles(bucket in a subdomain or in a URI).
%% We MUST get rid of a bucket part when the bucket is included in a URI.
%% There are 5 patterns to be handled by this function
%% Details are below.
%% +-----------------+------------------------+-------------------+
%% | Bucket          | URI                    | Expected          |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket">>          | <<"">>            |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket/">>         | <<"/">>           |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucketa">>         | <<"/bucketa">>    |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket/path">>     | <<"/path">>       |
%% +-----------------+------------------------+-------------------+
%% | <<"bucket">>    | <<"/bucket.ext">>      | <<"/bucket.ext">> |
%% +-----------------+------------------------+-------------------+
-spec(auth_uri(Bucket, URI, RequestedURI) ->
             binary() when Bucket::binary(),
                           URI::binary(),
                           RequestedURI::binary()).
auth_uri(<<>>, URI,_URI) ->
    URI;
auth_uri(_Bucket,<<"/">> = URI,_URI) ->
    URI;
auth_uri(Bucket,_URI, URI) ->
    case binary:match(URI, Bucket) of
        {1, _} ->
            BucketLen = byte_size(Bucket),
            BucketThresholdLen1 = BucketLen + 1,
            BucketThresholdLen2 = BucketLen + 2,
            URILen = byte_size(URI),

            case URILen of
                BucketThresholdLen1 ->
                    remove_duplicated_bucket(Bucket, URI);
                BucketThresholdLen2 ->
                    <<"/", Bucket:BucketLen/binary, LastChar:8>> = URI,
                    case LastChar == $/ of
                        true ->
                            %% /${Bucket}/ pattern are should be removed
                            remove_duplicated_bucket(Bucket, URI);
                        false ->
                            %% ex. /${Bucket}.
                            URI
                    end;
                _ ->
                    SegmentLen = length(binary:split(URI, <<"/">>, [global])),
                    case (SegmentLen >= 3) of
                        true ->
                            %% ex. /${Bucket}/path_to_file
                            remove_duplicated_bucket(Bucket, URI);
                        false ->
                            %% /${Bucket}[^/]+ pattern are should not be removed
                            URI
                    end
            end;
        _ ->
            URI
    end.


%% @doc remove duplicated bucket's name from path
%% @private
-spec(remove_duplicated_bucket(Bucket, URI) ->
             binary() when Bucket::binary(),
                           URI::binary()).
remove_duplicated_bucket(Bucket, URI) ->
    SkipSize = size(Bucket) + 1,
    binary:part(URI, {SkipSize, size(URI) - SkipSize}).


%% @doc Retrieve resources
%% @private
-spec(auth_resources(CannonocalizedResources) ->
             binary() when CannonocalizedResources::list()).
auth_resources(CannonocalizedResources) ->
    case lists:foldl(fun({K0, V0}, Acc0) ->
                             K1 = string:to_lower(K0),
                             case lists:keysearch(K1, 1, Acc0) of
                                 {value, {_, V1}} ->
                                     ordsets:add_element({K1, V1 ++ "," ++ V0},
                                                         lists:keydelete(K1, 1, Acc0));
                                 false ->
                                     ordsets:add_element({K1, V0}, Acc0)
                             end
                     end, [], CannonocalizedResources) of
        [] ->
            <<>>;
        Headers ->
            lists:foldl(fun({K2, V2}, Acc1) ->
                                BinKey =  list_to_binary(K2),
                                BinVal =  list_to_binary(V2),
                                <<Acc1/binary, BinKey/binary, ":", BinVal/binary, "\n" >>
                        end, <<>>, Headers)
    end.


%% @doc Retrieve sub-resources
%% @private
%% QueryStr must be sorted lexicographically by param name at caller
-spec(auth_sub_resources(QueryStr) ->
             binary() when QueryStr::binary()).
auth_sub_resources(QueryStr) ->
    ParamList = binary:split(QueryStr, [<<"?">>, <<"&">>], [global]),
    lists:foldl(fun(<<>>, Acc) ->
                        %% ignore empty elements
                        Acc;
                   (Param, <<>>) ->
                        %% append '?' to first param
                        [Key|Rest] = binary:split(Param, <<"=">>),
                        case binary:match(Key, ?SUB_RESOURCES) of
                            nomatch -> <<>>;
                            _ ->
                                case Rest of
                                    [] -> <<"?", Key/binary>>;
                                    [Val|_] ->
                                        DecodedVal = cow_qs:urldecode(Val),
                                        <<"?", Key/binary, "=", DecodedVal/binary>>
                                end
                        end;
                   (Param, Acc) ->
                        %% append '&' to other params
                        [Key|Rest] = binary:split(Param, <<"=">>),
                        case binary:match(Key, ?SUB_RESOURCES) of
                            nomatch -> Acc;
                            _ ->
                                case Rest of
                                    [] -> <<Acc/binary, "&", Key/binary>>;
                                    [Val|_] ->
                                        DecodedVal = cow_qs:urldecode(Val),
                                        <<Acc/binary, "&", Key/binary, "=", DecodedVal/binary>>
                                end
                        end
                end, <<>>, ParamList).


-ifdef(TEST).
auth_uri_test() ->
    Bucket = <<"photo">>,
    <<"">> = auth_uri(Bucket, <<"/photo">>, <<"/photo">>),
    <<"/photo">> = auth_uri(Bucket, <<"/photo">>, <<"/photo/photo">>),

    <<"/">> = auth_uri(Bucket, <<"/photo/">>, <<"/photo/">>),
    <<"/photo.txt">> = auth_uri(Bucket, <<"/photo/photo.txt">>, <<"/photo/photo.txt">>),
    <<"/photo.txt">> = auth_uri(Bucket, <<"/photo.txt">>, <<"/photo.txt">>).

-endif.
