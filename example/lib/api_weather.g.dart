// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_weather.dart';

// **************************************************************************
// RetrofitGenerator
// **************************************************************************

class _WeatherApi implements WeatherApi {
  _WeatherApi(this._dio) {
    ArgumentError.checkNotNull(_dio, '_dio');
    baseUrl = 'https://eolink.o.apispace.com';
  }

  final Dio _dio;

  late String baseUrl;

  @override
  Future<dynamic> get15DaysWeatherByArea(
    baseUrl,
    options,
    token,
    contentType,
    areacode,
  ) async {
    ArgumentError.checkNotNull(baseUrl, 'baseUrl');
    ArgumentError.checkNotNull(options, 'options');
    ArgumentError.checkNotNull(token, 'token');
    ArgumentError.checkNotNull(contentType, 'contentType');
    ArgumentError.checkNotNull(areacode, 'areacode');
    const _extra = <String, dynamic>{};
    final queryParameters = <String, dynamic>{r'areacode': areacode};
    Map<String, dynamic>? _data = <String, dynamic>{};
    final newOptions = newRequestOptions(options);
    newOptions.extra?.addAll(_extra);
    newOptions.headers?.addAll(<String, dynamic>{
      r'X-APISpace-Token': token,
      r'content-type': contentType,
    });
    final _result = await _dio.request(
      '$baseUrl/456456/weather/v001/now',
      queryParameters: queryParameters,
      options: newOptions.copyWith(
        method: 'GET',
        contentType: contentType,
      ),
      data: _data,
    );
    final value = _result.data;
    return value;
  }

  Options newRequestOptions(Options options) {
    return Options(
      method: options.method,
      sendTimeout: options.sendTimeout,
      receiveTimeout: options.receiveTimeout,
      extra: options.extra ?? {},
      headers: options.headers ?? {},
      responseType: options.responseType,
      contentType: options.contentType.toString(),
      validateStatus: options.validateStatus,
      receiveDataWhenStatusError: options.receiveDataWhenStatusError,
      followRedirects: options.followRedirects,
      maxRedirects: options.maxRedirects,
      requestEncoder: options.requestEncoder,
      responseDecoder: options.responseDecoder,
    );
  }
}
