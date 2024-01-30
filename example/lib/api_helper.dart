import 'dart:async';
import 'package:dio/dio.dart';
import 'api_weather.dart';
import 'dio_log_interceptor.dart';

class ApiHelper {
  ApiHelper.__privateConstructor();

  static final ApiHelper _instance = ApiHelper.__privateConstructor();
  static BaseOptions? _options;
  static late Dio _client;
  static final api = WeatherApi(
    _client,
  );

  factory ApiHelper() {
    _options = BaseOptions(
        connectTimeout: const Duration(seconds: 10000),
        receiveTimeout: const Duration(seconds: 10000));
    _client = Dio(_options);
    _client.interceptors.add(DioLogInterceptor());
    return _instance;
  }

  /// 发送短信验证码
  Future<dynamic> get15DaysWeatherByArea(String area) async {
    const token = '652gtcu41y43zjwfachycvkdgtyjkff3';
    final _options = Options(
        sendTimeout: const Duration(seconds: 100000),
        receiveTimeout: const Duration(seconds: 100000));
    return api.get15DaysWeatherByArea('https://eolink.o.apispace.com', _options,
        token, "application/json", area);
  }
}
