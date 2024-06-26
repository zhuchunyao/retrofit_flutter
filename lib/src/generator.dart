import 'dart:ffi';
import 'dart:io';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:built_collection/built_collection.dart';
import 'package:code_builder/code_builder.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:dart_style/dart_style.dart';
import 'package:source_gen/source_gen.dart';
import 'package:tuple/tuple.dart';
import 'package:dio/dio.dart';
import 'package:retrofit_flutter/src/retrofit.dart' as retrofit;

class RetrofitOptions {
  final bool? autoCastResponse;

  RetrofitOptions({this.autoCastResponse});

  RetrofitOptions.fromOptions([BuilderOptions? options])
      : autoCastResponse =
            (options?.config['auto_cast_response']?.toString() ?? 'true') ==
                'true';
}

class RetrofitGenerator extends GeneratorForAnnotation<retrofit.RestApi> {
  static const String _baseUrlVar = 'baseUrl';
  static const _queryParamsVar = 'queryParameters';
  static const _optionsVar = 'options';
  static const _dataVar = 'data';
  static const _localDataVar = 'requestData';
  static const _dioVar = '_dio';
  static const _extraVar = 'extra';
  static const _localExtraVar = 'requestExtra';
  static const _contentType = 'contentType';
  static const _resultVar = 'response';
  static const _cancelToken = 'cancelToken';
  static const _onSendProgress = 'onSendProgress';
  static const _onReceiveProgress = 'onReceiveProgress';
  var hasCustomOptions = false;

  /// Global options sepcefied in the `build.yaml`
  final RetrofitOptions globalOptions;

  RetrofitGenerator(this.globalOptions);

  /// Annotation details for [RestApi]
  late retrofit.RestApi clientAnnotation;

  @override
  String generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) {
    if (element is! ClassElement) {
      final name = element.displayName;
      throw InvalidGenerationSourceError(
        'Generator cannot target `$name`.',
        todo: 'Remove the [RestApi] annotation from `$name`.',
      );
    }
    return _implementClass(element, annotation);
  }

  String _implementClass(ClassElement element, ConstantReader annotation) {
    final className = element.name;
    final enumString = (annotation.peek('parser')?.revive().accessor);
    final parser = retrofit.Parser.values
        .firstWhereOrNull((e) => e.toString() == enumString);
    clientAnnotation = retrofit.RestApi(
      autoCastResponse: (annotation.peek('autoCastResponse')?.boolValue),
      baseUrl: (annotation.peek(_baseUrlVar)?.stringValue ?? ''),
      parser: (parser ?? retrofit.Parser.JsonSerializable),
    );
    final baseUrl = clientAnnotation.baseUrl;
    final cannotClassCosts = element.constructors
        .where((c) => !c.isFactory && !c.isDefaultConstructor);
    final classBuilder = Class((c) {
      c
        ..name = '_$className'
        ..types.addAll(element.typeParameters.map((e) => refer(e.name)))
        ..fields.addAll([_buildDioFiled(), _buildBaseUrlFiled(baseUrl)])
        ..constructors.addAll(
          cannotClassCosts.map(
            (e) => _generateConstructor(baseUrl, superClassConst: e),
          ),
        )
        ..methods.addAll(_parseMethods(element));
      if (cannotClassCosts.isEmpty) {
        c.constructors.add(_generateConstructor(baseUrl));
        c.implements.add(refer(_generateTypeParameterizedName(element)));
      } else {
        c.extend = Reference(_generateTypeParameterizedName(element));
      }
      if (hasCustomOptions) {
        c.methods.add(_generateOptionsCastMethod());
      }
    });

    final emitter = DartEmitter();
    return DartFormatter().format('${classBuilder.accept(emitter)}');
  }

  Field _buildDioFiled() => Field((m) => m
    ..name = _dioVar
    ..type = refer('Dio')
    ..modifier = FieldModifier.final$);

  Field _buildBaseUrlFiled(String? url) => Field((m) => m
    ..name = _baseUrlVar
    ..type = refer('late String')
    ..modifier = FieldModifier.var$);

  Constructor _generateConstructor(
    String? url, {
    ConstructorElement? superClassConst,
  }) =>
      Constructor((c) {
        c.requiredParameters.add(Parameter((p) => p
          ..name = _dioVar
          ..toThis = true));
        if (superClassConst != null) {
          var superConstName = 'super';
          if (superClassConst.name.isNotEmpty) {
            superConstName += '.${superClassConst.name}';
            c.name = superClassConst.name;
          }
          final constParams = superClassConst.parameters;
          constParams.forEach((element) {
            if (!element.isOptional || element.isPrivate) {
              c.requiredParameters.add(Parameter((p) => p
                ..type =
                    refer(element.type.getDisplayString(withNullability: true))
                ..name = element.name));
            } else {
              c.optionalParameters.add(Parameter((p) => p
                ..named = element.isNamed
                ..type =
                    refer(element.type.getDisplayString(withNullability: true))
                ..name = element.name));
            }
          });
          final paramList = constParams
              .map((e) => '${e.isNamed ? '${e.name}: ' : ''}${'${e.name}'}');
          c.initializers
              .add(Code('${'$superConstName('}${paramList.join(',')})'));
        }
        final block = [
          const Code("ArgumentError.checkNotNull($_dioVar,'$_dioVar');"),
          if (url != null && url.isNotEmpty)
            Code('$_baseUrlVar = ${literal(url)};'),
        ];

        c.body = Block.of(block);
      });

  Iterable<Method> _parseMethods(ClassElement element) =>
      element.methods.where((m) {
        final methodAnnot = _getMethodAnnotation(m);
        return methodAnnot != null &&
            m.isAbstract &&
            (m.returnType.isDartAsyncFuture || m.returnType.isDartAsyncStream);
      }).map(_generateMethod);

  String _generateTypeParameterizedName(TypeParameterizedElement element) =>
      element.displayName +
      (element.typeParameters.isNotEmpty
          ? '<${element.typeParameters.join(',')}>'
          : '');

  final _methodsAnnotations = const [
    retrofit.GET,
    retrofit.POST,
    retrofit.DELETE,
    retrofit.PUT,
    retrofit.PATCH,
    retrofit.HEAD,
    retrofit.OPTIONS,
    retrofit.Method
  ];

  TypeChecker _typeChecker(Type type) => TypeChecker.fromRuntime(type);

  ConstantReader? _getMethodAnnotation(MethodElement method) {
    for (final type in _methodsAnnotations) {
      final annot = _typeChecker(type)
          .firstAnnotationOf(method, throwOnUnresolved: false);
      if (annot != null) return ConstantReader(annot);
    }
    return null;
  }

  ConstantReader? _getHeadersAnnotation(MethodElement method) {
    final annot = _typeChecker(retrofit.Headers)
        .firstAnnotationOf(method, throwOnUnresolved: false);
    if (annot != null) return ConstantReader(annot);
    return null;
  }

  ConstantReader? _getUrlAnnotation(MethodElement method) {
    final annotation = _typeChecker(retrofit.Url)
        .firstAnnotationOf(method, throwOnUnresolved: false);
    if (annotation != null) return ConstantReader(annotation);
    return null;
  }

  ConstantReader? _getFormUrlEncodedAnnotation(MethodElement method) {
    final annotation = _typeChecker(retrofit.FormUrlEncoded)
        .firstAnnotationOf(method, throwOnUnresolved: false);
    if (annotation != null) return ConstantReader(annotation);
    return null;
  }

  ConstantReader? _getResponseTypeAnnotation(MethodElement method) {
    final annotation = _typeChecker(retrofit.DioResponseType)
        .firstAnnotationOf(method, throwOnUnresolved: false);
    if (annotation != null) return ConstantReader(annotation);
    return null;
  }

  Map<ParameterElement, ConstantReader> _getAnnotations(
      MethodElement m, Type type) {
    final cannot = <ParameterElement, ConstantReader>{};
    for (final p in m.parameters) {
      final a = _typeChecker(type).firstAnnotationOf(p);
      if (a != null) {
        cannot[p] = ConstantReader(a);
      }
    }
    return cannot;
  }

  Tuple2<ParameterElement, ConstantReader>? _getAnnotation(
      MethodElement m, Type type) {
    for (final p in m.parameters) {
      final a = _typeChecker(type).firstAnnotationOf(p);
      if (a != null) {
        return Tuple2(p, ConstantReader(a));
      }
    }
    return null;
  }

  List<DartType>? _genericListOf(DartType type) {
    return type is ParameterizedType && type.typeArguments.isNotEmpty
        ? type.typeArguments
        : null;
  }

  DartType? _genericOf(DartType type) {
    return type is InterfaceType && type.typeArguments.isNotEmpty
        ? type.typeArguments.first
        : null;
  }

  DartType? _getResponseType(DartType type) {
    return _genericOf(type);
  }

  /// get types for `Map<String, List<User>>`, `A<B,C,D>`
  List<DartType>? _getResponseInnerTypes(DartType type) {
    final genericList = _genericListOf(type);
    return genericList;
  }

  DartType? _getResponseInnerType(DartType type) {
    final generic = _genericOf(type);
    if (generic == null ||
        _typeChecker(Map).isExactlyType(type) ||
        _typeChecker(BuiltMap).isExactlyType(type)) return type;

    if (generic.isDynamic) return null;

    if (_typeChecker(List).isExactlyType(type) ||
        _typeChecker(BuiltList).isExactlyType(type)) return generic;

    return _getResponseInnerType(generic);
  }

  Method _generateMethod(MethodElement m) {
    final httpMethod = _getMethodAnnotation(m);

    return Method((mm) {
      mm
        ..returns =
            refer(m.type.returnType.getDisplayString(withNullability: true))
        ..name = m.displayName
        ..types.addAll(m.typeParameters.map((e) => refer(e.name)))
        ..modifier = m.returnType.isDartAsyncFuture
            ? MethodModifier.async
            : MethodModifier.asyncStar
        ..annotations.add(const CodeExpression(Code('override')));

      /// required parameters
      mm.requiredParameters.addAll(m.parameters
          .where((it) => it.isRequiredPositional || it.isRequiredNamed)
          .map((it) => Parameter((p) => p
            ..name = it.name
            ..named = it.isNamed)));

      /// optional positional or named parameters
      mm.optionalParameters.addAll(m.parameters.where((i) => i.isOptional).map(
          (it) => Parameter((p) => p
            ..name = it.name
            ..named = it.isNamed
            ..defaultTo = it.defaultValueCode == null
                ? null
                : Code(it.defaultValueCode!))));
      mm.body = _generateRequest(m, httpMethod!);
    });
  }

  Expression _generatePath(MethodElement m, ConstantReader method) {
    final paths = _getAnnotations(m, retrofit.Path);
    var definePath = method.peek('path')!.stringValue;
    paths.forEach((k, v) {
      final value = v.peek('value')?.stringValue ?? k.displayName;
      definePath = definePath.replaceFirst('{$value}', '\$${k.displayName}');
    });
    final url = _getUrlAnnotation(m);
    final _baseUrl = _getAnnotation(m, retrofit.BaseUrl)?.item1;
    var _hasBaseUrl = false;
    if (_baseUrl != null) {
      if (const TypeChecker.fromRuntime(String)
          .isAssignableFromType(_baseUrl.type)) {
        _hasBaseUrl = true;
      }
    }
    if (url != null) {
      if (!_hasBaseUrl) {
        final baseUrl = url.peek('url')!.stringValue;
        definePath = baseUrl + definePath;
      }
      return literal(definePath);
    } else {
      return literal('${'\$$_baseUrlVar'}$definePath');
    }
  }

  Code _generateRequest(MethodElement m, ConstantReader httpMethod) {
    final returnAsyncWrapper =
        m.returnType.isDartAsyncFuture ? 'return' : 'yield';
    final path = _generatePath(m, httpMethod);

    final blocks = <Code>[];

    for (final parameter in m.parameters.where((p) =>
        p.isRequiredNamed ||
        p.isRequiredPositional ||
        p.metadata.firstWhereOrNull((meta) => meta.isRequired) != null)) {
      blocks.add(Code('ArgumentError.checkNotNull('
          "${parameter.displayName},'${parameter.displayName}');"));
    }

    _generateExtra(m, blocks, _localExtraVar);

    _generateQueries(m, blocks, _queryParamsVar);
    final headers = _generateHeaders(m);
    _generateRequestBody(blocks, _localDataVar, m);

    final extraOptions = {
      'method': literal(httpMethod.peek('method')!.stringValue),
      'headers': literalMap(
          headers.map((k, v) => MapEntry(literalString(k!, raw: true), v)),
          refer('String'),
          refer('dynamic')),
      _extraVar: refer(_localExtraVar),
    };

    final contentTypeInHeader = headers.entries
        .firstWhereOrNull(
            (i) => 'Content-Type'.toLowerCase() == i.key!.toLowerCase())
        ?.value;
    if (contentTypeInHeader != null) {
      extraOptions[_contentType] = contentTypeInHeader;
    }

    final contentType = _getFormUrlEncodedAnnotation(m);
    if (contentType != null) {
      extraOptions[_contentType] =
          literal(contentType.peek('mime')!.stringValue);
    }

    final responseType = _getResponseTypeAnnotation(m);
    if (responseType != null) {
      final rsType = ResponseType.values.firstWhere((it) {
        return responseType
            .peek('responseType')!
            .objectValue
            .toString()
            .contains(it.toString().split('.')[1]);
      });

      extraOptions['responseType'] = refer(rsType.toString());
    }
    final namedArguments = <String, Expression>{};
    namedArguments[_queryParamsVar] = refer(_queryParamsVar);
    namedArguments[_optionsVar] =
        _parseOptions(m, namedArguments, blocks, extraOptions);
    namedArguments[_dataVar] = refer('$_localDataVar');

    final cancelToken = _getAnnotation(m, retrofit.CancelRequest);
    if (cancelToken != null) {
      namedArguments[_cancelToken] = refer(cancelToken.item1.displayName);
    }

    final sendProgress = _getAnnotation(m, retrofit.SendProgress);
    if (sendProgress != null) {
      namedArguments[_onSendProgress] = refer(sendProgress.item1.displayName);
    }

    final receiveProgress = _getAnnotation(m, retrofit.ReceiveProgress);
    if (receiveProgress != null) {
      namedArguments[_onReceiveProgress] =
          refer(receiveProgress.item1.displayName);
    }

    final wrappedReturnType = _getResponseType(m.returnType);
    final globalAutoCastResponse = globalOptions.autoCastResponse;
    final clientAutoCastResponse = clientAnnotation.autoCastResponse;
    final httpMethodAutoCastResponse =
        httpMethod.peek('autoCastResponse')?.boolValue;

    final autoCastResponse = globalAutoCastResponse != null
        ? globalAutoCastResponse
        : (clientAutoCastResponse != null
            ? clientAutoCastResponse
            : (httpMethodAutoCastResponse != null
                ? httpMethodAutoCastResponse
                : true));

    /// If autoCastResponse is false, return the response as it is
    if (!autoCastResponse) {
      blocks.add(
        refer('$_dioVar.request')
            .call([path], namedArguments)
            .returned
            .statement,
      );
      return Block.of(blocks);
    }

    if (wrappedReturnType == null || 'void' == wrappedReturnType.toString()) {
      blocks.add(
        refer('await $_dioVar.request')
            .call([path], namedArguments, [refer('void')])
            .statement,
      );
      blocks.add(Code('$returnAsyncWrapper null;'));
      return Block.of(blocks);
    }

    final isWrapped =
        _typeChecker(retrofit.HttpResponse).isExactlyType(wrappedReturnType);
    final returnType =
        isWrapped ? _getResponseType(wrappedReturnType) : wrappedReturnType;
    if (returnType == null || 'void' == returnType.toString()) {
      if (isWrapped) {
        blocks.add(
          refer('final $_resultVar = await $_dioVar.request')
              .call([path], namedArguments, [refer('void')])
              .statement,
        );
        blocks.add(Code('''
      final httpResponse = HttpResponse(null, $_resultVar);
      $returnAsyncWrapper httpResponse;
      '''));
      } else {
        blocks.add(
          refer('await $_dioVar.request')
              .call([path], namedArguments, [refer('void')])
              .statement,
        );
        blocks.add(Code('$returnAsyncWrapper null;'));
      }
    } else {
      final innerReturnType = _getResponseInnerType(returnType);
      if (_typeChecker(List).isExactlyType(returnType) ||
          _typeChecker(BuiltList).isExactlyType(returnType)) {
        if (_isBasicType(innerReturnType!)) {
          blocks.add(
            refer('await $_dioVar.request<List<dynamic>>')
                .call([path], namedArguments)
                .assignFinal(_resultVar)
                .statement,
          );
          blocks.add(
              Code('final value = $_resultVar.data.cast<$innerReturnType>();'));
        } else {
          blocks.add(
            refer('await $_dioVar.request<List<dynamic>>')
                .call([path], namedArguments)
                .assignFinal(_resultVar)
                .statement,
          );
          if (clientAnnotation.parser != null)
            switch (clientAnnotation.parser!) {
              case retrofit.Parser.MapSerializable:
                blocks
                    .add(Code('var value = $_resultVar.data.map((dynamic i) => '
                        '$innerReturnType.fromMap(i as Map<'
                        'String,dynamic>)).toList();'));
                break;
              case retrofit.Parser.JsonSerializable:
                blocks
                    .add(Code('var value = $_resultVar.data.map((dynamic i) => '
                        '$innerReturnType.fromJson(i as Map<'
                        'String,dynamic>)).toList();'));
                break;
              case retrofit.Parser.DartJsonMapper:
                blocks.add(Code('var value = $_resultVar.data.map((dynamic i) '
                    '=> JsonMapper.deserialize<'
                    '$innerReturnType>(i as Map<String,dynamic>)).toList();'));
                break;
            }
        }
      } else if (_typeChecker(Map).isExactlyType(returnType) ||
          _typeChecker(BuiltMap).isExactlyType(returnType)) {
        final types = _getResponseInnerTypes(returnType)!;
        blocks.add(
          refer('await $_dioVar.request<Map<String,dynamic>>')
              .call([path], namedArguments)
              .assignFinal(_resultVar)
              .statement,
        );

        /// assume the first type is a basic type
        if (types.length > 1) {
          final secondType = types[1];
          if (_typeChecker(List).isExactlyType(secondType) ||
              _typeChecker(BuiltList).isExactlyType(secondType)) {
            final type = _getResponseType(secondType);
            if (clientAnnotation.parser != null)
              switch (clientAnnotation.parser!) {
                case retrofit.Parser.MapSerializable:
                  blocks.add(Code('''
            var value = $_resultVar.data
              .map((k, dynamic v) =>
                MapEntry(
                  k, (v as List)
                    .map((i) => $type.fromMap(i as Map<String,dynamic>))
                    .toList()
                )
              );
            '''));
                  break;
                case retrofit.Parser.JsonSerializable:
                  blocks.add(Code('''
            var value = $_resultVar.data
              .map((k, dynamic v) =>
                MapEntry(
                  k, (v as List)
                    .map((i) => $type.fromJson(i as Map<String,dynamic>))
                    .toList()
                )
              );
            '''));
                  break;
                case retrofit.Parser.DartJsonMapper:
                  blocks.add(Code('''
            var value = $_resultVar.data
              .map((k, dynamic v) =>
                MapEntry(
                  k, (v as List)
                    .map((i) => JsonMapper.deserialize<$type>(i as Map<String,dynamic>))
                    .toList()
                )
              );
            '''));
                  break;
              }
          } else if (!_isBasicType(secondType)) {
            if (clientAnnotation.parser != null)
              switch (clientAnnotation.parser!) {
                case retrofit.Parser.MapSerializable:
                  blocks.add(Code('''
            var value = $_resultVar.data
              .map((k, dynamic v) =>
                MapEntry(k, $secondType.fromMap(v as Map<String, dynamic>))
              );
            '''));
                  break;
                case retrofit.Parser.JsonSerializable:
                  blocks.add(Code('''
            var value = $_resultVar.data
              .map((k, dynamic v) =>
                MapEntry(k, $secondType.fromJson(v as Map<String, dynamic>))
              );
            '''));
                  break;
                case retrofit.Parser.DartJsonMapper:
                  blocks.add(Code('''
            var value = $_resultVar.data
              .map((k, dynamic v) =>
                MapEntry(k, JsonMapper.deserialize<$secondType>(v as Map<String, dynamic>))
              );
            '''));
                  break;
              }
          }
        } else {
          blocks.add(const Code('final value = $_resultVar.data;'));
        }
      } else {
        if (_isBasicType(returnType)) {
          blocks.add(
            refer('await $_dioVar.request<$returnType>')
                .call([path], namedArguments)
                .assignFinal(_resultVar)
                .statement,
          );
          blocks.add(const Code('final value = $_resultVar.data;'));
        } else if (returnType.toString() == 'dynamic') {
          blocks.add(
            refer('await $_dioVar.request')
                .call([path], namedArguments)
                .assignFinal(_resultVar)
                .statement,
          );
          blocks.add(const Code('final value = $_resultVar.data;'));
        } else {
          blocks.add(
            refer('await $_dioVar.request<Map<String,dynamic>>')
                .call([path], namedArguments)
                .assignFinal(_resultVar)
                .statement,
          );
          if (clientAnnotation.parser != null)
            switch (clientAnnotation.parser!) {
              case retrofit.Parser.MapSerializable:
                blocks.add(Code(
                    'final value = $returnType.fromMap($_resultVar.data);'));
                break;
              case retrofit.Parser.JsonSerializable:
                blocks.add(Code(
                    'final value = $returnType.fromJson($_resultVar.data!);'));
                blocks.add(
                    const Code('value.statusCode = $_resultVar.statusCode;'));
                break;
              case retrofit.Parser.DartJsonMapper:
                blocks.add(Code('final value = JsonMapper.deserialize<'
                    '$returnType>($_resultVar.data);'));
                break;
            }
        }
      }
      if (isWrapped) {
        blocks.add(Code('''
      final httpResponse = HttpResponse(value, $_resultVar);
      $returnAsyncWrapper httpResponse;
      '''));
      } else {
        blocks.add(Code('$returnAsyncWrapper value;'));
      }
    }

    return Block.of(blocks);
  }

  Expression _parseOptions(
      MethodElement m,
      Map<String, Expression> namedArguments,
      List<Code> blocks,
      Map<String, Expression> extraOptions) {
    final options = refer('Options').newInstance([], extraOptions);
    final annoyOptions = _getAnnotation(m, retrofit.DioOptions);
    if (annoyOptions == null) {
      return options;
    } else {
      hasCustomOptions = true;
      blocks.add(refer('newRequestOptions')
          .call([refer(annoyOptions.item1.displayName)])
          .assignFinal('newOptions')
          .statement);
      final newOptions = refer('newOptions');
      blocks.add(newOptions
          .property('$_extraVar?')
          .property('addAll')
          .call([extraOptions.remove(_extraVar)!]).statement);
      blocks.add(newOptions
          .property('headers?')
          .property('addAll')
          .call([extraOptions.remove('headers')!]).statement);
      return newOptions.property('copyWith').call([], extraOptions);
    }
  }

  Method _generateOptionsCastMethod() {
    return Method((m) {
      m
        ..name = 'newRequestOptions'
        ..returns = refer('Options')

        /// required parameters
        ..requiredParameters.add(Parameter((p) {
          p.name = 'options';
          p.type = refer('Options').type;
        }))

        /// add method body
        ..body = const Code('''
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
        ''');
    });
  }

  bool _isBasicType(DartType returnType) {
    return _typeChecker(String).isExactlyType(returnType) ||
        _typeChecker(bool).isExactlyType(returnType) ||
        _typeChecker(int).isExactlyType(returnType) ||
        _typeChecker(double).isExactlyType(returnType) ||
        _typeChecker(num).isExactlyType(returnType) ||
        _typeChecker(Double).isExactlyType(returnType) ||
        _typeChecker(Float).isExactlyType(returnType);
  }

  void _generateQueries(
      MethodElement m, List<Code> blocks, String _queryParamsVar) {
    final queries = _getAnnotations(m, retrofit.Query);
    final queryParameters = queries.map((p, r) {
      final key = r.peek('value')?.stringValue ?? p.displayName;
      final value = (_isBasicType(p.type) ||
              p.type.isDartCoreList ||
              p.type.isDartCoreMap)
          ? refer(p.displayName)
          : clientAnnotation.parser == retrofit.Parser.DartJsonMapper
              ? refer(p.displayName)
              : clientAnnotation.parser == retrofit.Parser.JsonSerializable
                  ? refer(p.displayName).nullSafeProperty('toJson').call([])
                  : refer(p.displayName).nullSafeProperty('toMap').call([]);
      return MapEntry(literalString(key, raw: true), value);
    });

    final queryMap = _getAnnotations(m, retrofit.Queries);
    blocks.add(literalMap(queryParameters, refer('String'), refer('dynamic'))
        .assignFinal(_queryParamsVar)
        .statement);
    for (final p in queryMap.keys) {
      final type = p.type;
      final displayName = p.displayName;
      final value =
          (_isBasicType(type) || type.isDartCoreList || type.isDartCoreMap)
              ? refer(displayName)
              : clientAnnotation.parser == retrofit.Parser.DartJsonMapper
                  ? refer(displayName)
                  : clientAnnotation.parser == retrofit.Parser.JsonSerializable
                      ? refer(displayName).nullSafeProperty('toJson').call([])
                      : refer(displayName).nullSafeProperty('toMap').call([]);

      /// workaround until this is merged in code_builder
      /// https://github.com/dart-lang/code_builder/pull/269
      final emitter = DartEmitter();
      final buffer = StringBuffer();
      value.accept(emitter, buffer);
      refer('?? <String,dynamic>{}').accept(emitter, buffer);
      final expression = refer(buffer.toString());

      blocks.add(refer('$_queryParamsVar.addAll').call([expression]).statement);
    }

    if (m.parameters
        .where((p) => (p.isOptional && !p.isRequiredNamed))
        .isNotEmpty) {
      blocks.add(Code('$_queryParamsVar.removeWhere((k, v) => v == null);'));
    }
  }

  void _generateRequestBody(
      List<Code> blocks, String _dataVar, MethodElement m) {
    final _bodyName = _getAnnotation(m, retrofit.Body)?.item1;
    if (_bodyName != null) {
      if (const TypeChecker.fromRuntime(Map)
          .isAssignableFromType(_bodyName.type)) {
        blocks.add(
            Code('Map<String, dynamic>? $_dataVar = <String, dynamic>{};'));
        blocks.add(refer('$_dataVar.addAll').call([
          refer('${_bodyName.displayName} ?? <String,dynamic>{}')
        ]).statement);
        blocks.add(Code('$_dataVar.removeWhere((k, v) => v == null);'));
        blocks.add(Code('''if ($_dataVar.isEmpty) {
      $_dataVar = null;
    }'''));
      } else if (_typeChecker(File).isExactly(_bodyName.type.element!)) {
        blocks.add(refer('Stream')
            .property('fromIterable')
            .call([
              refer('${_bodyName.displayName}.readAsBytesSync().map((i)=>[i])')
            ])
            .assignFinal(_dataVar)
            .statement);
      } else if (_bodyName.type.element is ClassElement) {
        final ele = _bodyName.type.element as ClassElement?;
        if (clientAnnotation.parser == retrofit.Parser.MapSerializable) {
          final toMap = ele!.lookUpMethod('toMap', ele.library);
          if (toMap == null) {
            log.warning('${_bodyName.type} must provide a `toMap()` '
                'method which return a Map.\n'
                "It is programmer's responsibility to make sure the "
                '${_bodyName.type} is properly serialized');
            blocks.add(
                refer(_bodyName.displayName).assignFinal(_dataVar).statement);
          } else {
            blocks.add(
                Code('Map<String, dynamic>? $_dataVar = <String, dynamic>{};'));
            blocks.add(refer('$_dataVar.addAll').call([
              refer('${_bodyName.displayName}?.toMap() ?? <String,dynamic>{}')
            ]).statement);
            blocks.add(Code('$_dataVar.removeWhere((k, v) => v == null);'));
            blocks.add(Code('''if ($_dataVar.isEmpty) {
      $_dataVar = null;
    }'''));
          }
        } else {
          final toJson = ele!.lookUpMethod('toJson', ele.library);
          if (toJson == null) {
            log.warning('${_bodyName.type} must provide a `toJson()` '
                'method which return a Map.\n'
                "It is programmer's responsibility to make sure the "
                '${_bodyName.type} is properly serialized');
            blocks.add(
                refer(_bodyName.displayName).assignFinal(_dataVar).statement);
          } else {
            blocks.add(
                Code('Map<String, dynamic>? $_dataVar = <String, dynamic>{};'));
            blocks.add(refer('$_dataVar.addAll').call([
              refer('${_bodyName.displayName}?.toJson() ?? <String,dynamic>{}')
            ]).statement);
            blocks.add(Code('$_dataVar.removeWhere((k, v) => v == null);'));
            blocks.add(Code('''if ($_dataVar.isEmpty) {
      $_dataVar = null;
    }'''));
          }
        }
      } else {
        /// @Body annotations with no type are assinged as is
        blocks
            .add(refer(_bodyName.displayName).assignFinal(_dataVar).statement);
      }

      return;
    }

    final fields = _getAnnotations(m, retrofit.Field).map((p, r) {
      final fieldName = r.peek('value')?.stringValue ?? p.displayName;
      final isFileField = _typeChecker(File).isAssignableFromType(p.type);
      if (isFileField) {
        log.severe(
            'File is not support by @Field(). Please use @Part() instead.');
      }
      return MapEntry(literal(fieldName), refer(p.displayName));
    });

    if (fields.isNotEmpty) {
      blocks.add(literalMap(fields).assignFinal(_dataVar).statement);
      blocks.add(Code('$_dataVar.removeWhere((k, v) => v == null);'));
      return;
    }

    final parts = _getAnnotations(m, retrofit.Part);
    if (parts.isNotEmpty) {
      blocks.add(
          refer('FormData').newInstance([]).assignFinal(_dataVar).statement);

      parts.forEach((p, r) {
        final fieldName = r.peek('name')?.stringValue ??
            r.peek('value')?.stringValue ??
            p.displayName;
        final isFileField = _typeChecker(File).isAssignableFromType(p.type);
        final contentType = r.peek('contentType')?.stringValue;

        if (isFileField) {
          final tempName = r.peek('fileName')?.stringValue;
          final fileName = tempName != null
              ? literalString(tempName)
              : refer(p.displayName)
                  .property('path.split(Platform.pathSeparator).last');

          final uploadFileInfo = refer('$MultipartFile.fromFileSync').call([
            refer(p.displayName).property('path')
          ], {
            'filename': fileName,
            if (contentType != null)
              'contentType':
                  refer('MediaType', 'package:http_parser/http_parser.dart')
                      .property('parse')
                      .call([literal(contentType)])
          });

          final optionalFile = m.parameters
                      .firstWhere((pp) => pp.displayName == p.displayName)
                      .isOptional !=
                  null
              ? m.parameters
                  .firstWhere((pp) => pp.displayName == p.displayName)
                  .isOptional
              : false;

          final returnCode =
              refer(_dataVar).property('files').property('add').call([
            refer('MapEntry').newInstance([literal(fieldName), uploadFileInfo])
          ]).statement;
          if (optionalFile) {
            final condition = refer(p.displayName).notEqualTo(literalNull).code;
            blocks.addAll([
              const Code('if('),
              condition,
              const Code(') {'),
              returnCode,
              const Code('}')
            ]);
          } else {
            blocks.add(returnCode);
          }
        } else if (p.type.getDisplayString(withNullability: true) ==
            'List<int>') {
          final fileName = r.peek('fileName')?.stringValue;
          final conType = contentType == null
              ? ''
              : 'contentType: MediaType.parse(${literal(contentType)}),';
          blocks.add(refer(_dataVar).property('files').property('add').call([
            refer(''' 
                  MapEntry(
                '$fieldName',
                MultipartFile.fromBytes(${p.displayName},
                filename:${literal(fileName)},
                    $conType
                    ))
                  ''')
          ]).statement);
        } else if (_typeChecker(List).isExactlyType(p.type) ||
            _typeChecker(BuiltList).isExactlyType(p.type)) {
          final innerType = _genericOf(p.type)!;

          if (innerType.getDisplayString(withNullability: true) ==
              'List<int>') {
            final conType = contentType == null
                ? ''
                : 'contentType: MediaType.parse(${literal(contentType)}),';
            blocks
                .add(refer(_dataVar).property('files').property('addAll').call([
              refer(''' 
                  ${p.displayName}?.map((i) => MapEntry(
                '$fieldName',
                MultipartFile.fromBytes(i,
                    $conType
                    )))
                  ''')
            ]).statement);
          } else if (_isBasicType(innerType) ||
              _typeChecker(Map).isExactlyType(innerType) ||
              _typeChecker(BuiltMap).isExactlyType(innerType) ||
              _typeChecker(List).isExactlyType(innerType) ||
              _typeChecker(BuiltList).isExactlyType(innerType)) {
            final value = _isBasicType(innerType) ? 'i' : 'jsonEncode(i)';
            blocks.add(refer('''
            ${p.displayName}?.forEach((i){
              $_dataVar.fields.add(MapEntry(${literal(fieldName)},$value));
            })
            ''').statement);
          } else if (_typeChecker(File).isExactlyType(innerType)) {
            final conType = contentType == null
                ? ''
                : 'contentType: MediaType.parse(${literal(contentType)}),';
            blocks
                .add(refer(_dataVar).property('files').property('addAll').call([
              refer(''' 
                  ${p.displayName}?.map((i) => MapEntry(
                '$fieldName',
                MultipartFile.fromFileSync(i.path,
                    filename: i.path.split(Platform.pathSeparator).last,
                    $conType
                    )))
                  ''')
            ]).statement);
          } else if (innerType.element is ClassElement) {
            final ele = innerType.element as ClassElement;
            final toJson = ele.lookUpMethod('toJson', ele.library);
            if (toJson == null) {
              throw Exception('toJson() method have to add to ${p.type}');
            } else {
              blocks
                  .add(refer(_dataVar).property('fields').property('add').call([
                refer('MapEntry').newInstance(
                    [literal(fieldName), refer('jsonEncode(${p.displayName})')])
              ]).statement);
            }
          } else {
            throw Exception('Unknown error!');
          }
        } else if (_isBasicType(p.type)) {
          blocks.add(Code('if (${p.displayName} != null) {'));
          blocks.add(refer(_dataVar).property('fields').property('add').call([
            refer('MapEntry').newInstance([
              literal(fieldName),
              if (_typeChecker(String).isExactlyType(p.type))
                refer(p.displayName)
              else
                refer(p.displayName).property('toString').call([])
            ])
          ]).statement);
          blocks.add(const Code('}'));
        } else if (_typeChecker(Map).isExactlyType(p.type) ||
            _typeChecker(BuiltMap).isExactlyType(p.type)) {
          blocks.add(refer(_dataVar).property('fields').property('add').call([
            refer('MapEntry').newInstance(
                [literal(fieldName), refer('jsonEncode(${p.displayName})')])
          ]).statement);
        } else if (p.type.element is ClassElement) {
          final ele = p.type.element as ClassElement;
          final toJson = ele.lookUpMethod('toJson', ele.library);
          if (toJson == null) {
            throw Exception('toJson() method have to add to ${p.type}');
          } else {
            blocks.add(refer(_dataVar).property('fields').property('add').call([
              refer('MapEntry').newInstance([
                literal(fieldName),
                refer('jsonEncode(${p.displayName}?? <String,dynamic>{})')
              ])
            ]).statement);
          }
        } else {
          blocks.add(refer(_dataVar).property('fields').property('add').call([
            refer('MapEntry')
                .newInstance([literal(fieldName), refer(p.displayName)])
          ]).statement);
        }
      });
      return;
    }

    /// There is no body
    blocks.add(Code('Map<String, dynamic>? $_dataVar;'));
  }

  Map<String?, Expression> _generateHeaders(MethodElement m) {
    final anno = _getHeadersAnnotation(m);
    final headersMap = anno?.peek('value')?.mapValue ?? {};
    final headers = headersMap.map((k, v) {
      return MapEntry(k!.toStringValue(), literal(v!.toStringValue()));
    });

    final annosInParam = _getAnnotations(m, retrofit.Header);
    final headersInParams = annosInParam.map((k, v) {
      final key = v.peek('value')?.stringValue ?? k.displayName;
      headers.keys
          .where((element) => element.toString() == key.toString())
          .toList()
          .forEach(headers.remove);
      return MapEntry(key, refer(k.displayName));
    });

    headers.addAll(headersInParams);
    return headers;
  }

  void _generateExtra(
      MethodElement m, List<Code> blocks, String localExtraVar) {
    final extra = _typeChecker(retrofit.Extra)
        .firstAnnotationOf(m, throwOnUnresolved: false);
    if (extra != null) {
      final c = ConstantReader(extra);
      final extraMap = c.peek('data')?.mapValue.map((k, v) {
            final stringValue = k?.toStringValue();
            final result = stringValue != null
                ? literalString(stringValue, raw: true)
                : throw InvalidGenerationSourceError(
                    'Invalid key for extra Map, only `String` keys are supported',
                    element: m,
                    todo: 'Make sure all keys are of string type',
                  );
            return MapEntry(
              result,
              v!.toBoolValue() ??
                  v.toDoubleValue() ??
                  v.toIntValue() ??
                  v.toStringValue() ??
                  v.toListValue() ??
                  v.toMapValue() ??
                  v.toSetValue() ??
                  v.toSymbolValue() ??
                  v.toTypeValue() ??
                  Code('const ${revivedLiteral(v)}'),
            );
          }) ??
          {};
      final annoysInParam = _getAnnotations(m, retrofit.Cache);
      final cacheInParams = annoysInParam.map((k, v) {
        final value = v.peek('value')?.stringValue ?? k.displayName;
        final key = literalString(value, raw: true);
        extraMap.keys
            .where((element) => element.toString() == key.toString())
            .toList()
            .forEach(extraMap.remove);
        return MapEntry(key, refer(k.displayName));
      });
      if (cacheInParams.isNotEmpty) {
        extraMap.addAll(cacheInParams);
      }
      blocks.add(literalMap(extraMap).assignFinal(localExtraVar).statement);
    } else {
      final extraMap = {};
      final annoysInParam = _getAnnotations(m, retrofit.Cache);
      final cacheInParams = annoysInParam.map((k, v) {
        final value = v.peek('value')?.stringValue ?? k.displayName;
        return MapEntry(literalString(value, raw: true), refer(k.displayName));
      });
      if (cacheInParams.isNotEmpty) {
        extraMap.addAll(cacheInParams);
        blocks.add(literalMap(extraMap).assignFinal(localExtraVar).statement);
      } else {
        blocks.add(literalMap(
          {},
          refer('String'),
          refer('dynamic'),
        ).assignConst(localExtraVar).statement);
      }
    }
  }
}

Builder generatorFactoryBuilder(BuilderOptions options) => SharedPartBuilder(
    [RetrofitGenerator(RetrofitOptions.fromOptions(options))], 'retrofit');

/// Returns `$revived($args $kwargs)`, this won't have ending semi-colon (`;`).
/// [object] must not be null.
/// [object] is assumed to be a constant.
String revivedLiteral(
  Object object, {
  DartEmitter? dartEmitter,
}) {
  dartEmitter ??= DartEmitter();

  ArgumentError.checkNotNull(object, 'object');

  Revivable? revived;
  if (object is Revivable) {
    revived = object;
  }
  if (object is DartObject) {
    revived = ConstantReader(object).revive();
  }
  if (object is ConstantReader) {
    revived = object.revive();
  }
  if (revived == null) {
    throw ArgumentError.value(
        object,
        'object',
        'Only `Revivable`, `DartObject`, '
            '`ConstantReader` are supported values');
  }

  var instantiation = '';
  final location = revived.source.toString().split('#');

  /// If this is a class instantiation then `location[1]` will be populated
  /// with the class name
  if (location.length > 1) {
    instantiation = location[1] +
        (revived.accessor.isNotEmpty ? '.${revived.accessor}' : '');
  } else {
    /// Getters, Setters, Methods can't be declared as constants so this
    /// literal must either be a top-level constant or a static constant and
    /// can be directly accessed by `revived.accessor`
    return revived.accessor;
  }

  final args = StringBuffer();
  final kwargs = StringBuffer();
  Spec objectToSpec(DartObject? object) {
    final constant = ConstantReader(object);
    if (constant.isNull) {
      return literalNull;
    }

    if (constant.isBool) {
      return literal(constant.boolValue);
    }

    if (constant.isDouble) {
      return literal(constant.doubleValue);
    }

    if (constant.isInt) {
      return literal(constant.intValue);
    }

    if (constant.isString) {
      return literal(constant.stringValue);
    }

    if (constant.isList) {
      return literalList(constant.listValue.map(objectToSpec));
      // return literal(constant.listValue);
    }

    if (constant.isMap) {
      return literalMap(Map.fromIterables(
          constant.mapValue.keys.map(objectToSpec),
          constant.mapValue.values.map(objectToSpec)));
      // return literal(constant.mapValue);
    }

    if (constant.isSymbol) {
      return Code('Symbol(${constant.symbolValue.toString()})');
      // return literal(constant.symbolValue);
    }

    if (constant.isNull) {
      return literalNull;
    }

    if (constant.isType) {
      return refer(constant.typeValue.getDisplayString(withNullability: true));
    }

    if (constant.isLiteral) {
      return literal(constant.literalValue);
    }

    /// Perhaps an object instantiation?
    /// In that case, try initializing it and remove `const` to reduce noise
    final revived = revivedLiteral(constant.revive(), dartEmitter: dartEmitter)
        .replaceFirst('const ', '');
    return Code(revived);
  }

  for (final arg in revived.positionalArguments) {
    final literalValue = objectToSpec(arg);

    args.write('${literalValue.accept(dartEmitter)},');
  }

  for (final arg in revived.namedArguments.keys) {
    final literalValue = objectToSpec(revived.namedArguments[arg]);

    kwargs.write('$arg:${literalValue.accept(dartEmitter)},');
  }

  return '$instantiation($args $kwargs)';
}

extension DartTypeStreamAnnotation on DartType {
  bool get isDartAsyncStream {
    final element = this.element as ClassElement?;
    if (element == null) {
      return false;
    }
    return element.name == 'Stream' && element.library.isDartAsync;
  }
}
