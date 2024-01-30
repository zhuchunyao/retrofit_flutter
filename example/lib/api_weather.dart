import 'package:dio/dio.dart';
import 'package:retrofit_flutter/retrofit_flutter.dart';

import 'response_weather.dart';

part 'api_weather.g.dart';

@RestApi(baseUrl: 'https://eolink.o.apispace.com')
abstract class WeatherApi {
  factory WeatherApi(Dio dio) = _WeatherApi;

  @GET('/456456/weather/v001/now')
  Future<dynamic> get15DaysWeatherByArea(@BaseUrl() String baseUrl,
      @DioOptions() Options options,
      @Header('X-APISpace-Token')String token,
      @Header('content-type')String contentType,
      @Query('areacode') String areacode);
}
