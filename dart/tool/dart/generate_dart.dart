// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library generate_vm_service_lib_dart;

import 'package:markdown/markdown.dart';

import '../common/generate_common.dart';
import '../common/parser.dart';
import '../common/src_gen_common.dart';
import 'src_gen_dart.dart';

export 'src_gen_dart.dart' show DartGenerator;

Api api;

String _coerceRefType(String typeName) {
  if (typeName == 'Object') typeName = 'Obj';
  if (typeName == '@Object') typeName = 'ObjRef';
  if (typeName == 'Function') typeName = 'Func';
  if (typeName == '@Function') typeName = 'FuncRef';
  if (typeName.startsWith('@')) typeName = typeName.substring(1) + 'Ref';
  if (typeName == 'string') typeName = 'String';
  return typeName;
}

final String _headerCode = r'''
// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This is a generated file.

/// A library to access the VM Service API.
///
/// The main entry-point for this library is the [VmService] class.
library vm_service_lib;

import 'dart:async';
import 'dart:convert' show BASE64, JSON, JsonCodec;

''';

final String _implCode = r'''

  /// Invoke a specific service protocol extension method.
  ///
  /// See https://api.dartlang.org/stable/dart-developer/dart-developer-library.html.
  Future<Response> callServiceExtension(String method, [Map args]) {
    return _call(method, args);
  }

  Stream<String> get onSend => _onSend.stream;

  Stream<String> get onReceive => _onReceive.stream;

  void dispose() {
    _streamSub.cancel();
    _completers.values.forEach((c) => c.completeError('disposed'));
  }

  Future<Response> _call(String method, [Map args]) {
    String id = '${++_id}';
    _completers[id] = new Completer<Response>();
    Map m = {'id': id, 'method': method};
    if (args != null) m['params'] = args;
    String message = JSON.encode(m);
    _onSend.add(message);
    _writeMessage(message);
    return _completers[id].future;
  }

  void _processMessage(String message) {
    try {
      _onReceive.add(message);

      var json = JSON.decode(message);
      if (json['id'] == null && json['method'] == 'streamNotify') {
        Map params = json['params'];
        String streamId = params['streamId'];
        _getEventController(streamId).add(_createObject(params['event']));
      } else if (json['id'] != null) {
        Completer completer = _completers.remove(json['id']);

        if (completer == null) {
          _log.severe('unmatched request response: ${message}');
        } else if (json['error'] != null) {
          completer.completeError(RPCError.parse(json['error']));
        } else {
          var result = json['result'];
          String type = result['type'];
          if (_typeFactories[type] == null) {
            completer.complete(Response.parse(result));
          } else {
            completer.complete(_createObject(result));
          }
        }
      } else {
        _log.severe('unknown message type: ${message}');
      }
    } catch (e, s) {
      _log.severe('unable to decode message: ${message}, ${e}\n${s}');
    }
  }
''';

final String _rpcError = r'''
class RPCError {
  static RPCError parse(dynamic json) {
    return new RPCError(json['code'], json['message'], json['data']);
  }

  final int code;
  final String message;
  final Map data;

  RPCError(this.code, this.message, [this.data]);

  String toString() => '${code}: ${message}';
}

/// A logging handler you can pass to a [VmService] instance in order to get
/// notifications of non-fatal service protcol warnings and errors.
abstract class Log {
  /// Log a warning level message.
  void warning(String message);

  /// Log an error level message.
  void severe(String message);
}

class _NullLog implements Log {
  void warning(String message) { }
  void severe(String message) { }
}
''';

abstract class Member {
  String get name;
  String get docs => null;
  void generate(DartGenerator gen);

  bool get hasDocs => docs != null;

  String toString() => name;
}

class Api extends Member with ApiParseUtil {
  String serviceVersion;
  List<Method> methods = [];
  List<Enum> enums = [];
  List<Type> types = [];

  void parse(List<Node> nodes) {
    serviceVersion = ApiParseUtil.parseVersionString(nodes);

    // Look for h3 nodes
    // the pre following it is the definition
    // the optional p following that is the documentation

    String h3Name = null;

    for (int i = 0; i < nodes.length; i++) {
      Node node = nodes[i];

      if (isPre(node) && h3Name != null) {
        String definition = textForCode(node);
        String docs = '';

        while (i + 1 < nodes.length &&
            (isPara(nodes[i + 1]) || isBlockquote(nodes[i + 1]))) {
          Element p = nodes[++i];
          String str = TextOutputVisitor.printText(p);
          if (!str.contains('|') && !str.contains('``')) str = collapseWhitespace(str);
          docs = '${docs}\n\n${str}';
        }

        docs = docs.trim();
        if (docs.isEmpty) docs = null;

        _parse(h3Name, definition, docs);
      } else if (isH3(node)) {
        h3Name = textForElement(node);
      } else if (isHeader(node)) {
        h3Name = null;
      }
    }
  }

  String get name => 'api';
  String get docs => null;

  void _parse(String name, String definition, [String docs]) {
    name = name.trim();
    definition = definition.trim();
    if (docs != null) docs = docs.trim();

    if (name.substring(0, 1).toLowerCase() == name.substring(0, 1)) {
      methods.add(new Method(name, definition, docs));
    } else if (definition.startsWith('class ')) {
      types.add(new Type(this, name, definition, docs));
    } else if (definition.startsWith('enum ')) {
      enums.add(new Enum(name, definition, docs));
    } else {
      throw 'unexpected entity: ${name}, ${definition}';
    }
  }

  static String printNode(Node n) {
    if (n is Text) {
      return n.text;
    } else if (n is Element) {
      if (n.tag != 'h3') return n.tag;
      return '${n.tag}:[${n.children.map((c) => printNode(c)).join(', ')}]';
    } else {
      return '${n}';
    }
  }

  void generate(DartGenerator gen) {
    // Set default value for unspecified property
    setDefaultValue('Instance', 'valueAsStringIsTruncated', 'false');
    setDefaultValue('InstanceRef', 'valueAsStringIsTruncated', 'false');

    gen.out(_headerCode);
    gen.writeln("const String vmServiceVersion = '${serviceVersion}';");
    gen.writeln();
    gen.writeln('''
/// @optional
const String optional = 'optional';

/// Decode a string in Base64 encoding into the equivalent non-encoded string.
/// This is useful for handling the results of the Stdout or Stderr events.
String decodeBase64(String str) => new String.fromCharCodes(BASE64.decode(str));

Object _createObject(dynamic json) {
  if (json == null) return null;

  if (json is List) {
    return (json as List).map((e) => _createObject(e)).toList();
  } else if (json is Map) {
    String type = json['type'];
    if (_typeFactories[type] == null) {
      return null;
    } else {
      return _typeFactories[type](json);
    }
  } else {
    // Handle simple types.
    return json;
  }
}

''');
    gen.writeln();
    gen.write('Map<String, Function> _typeFactories = {');
    types.forEach((Type type) {
      gen.write("'${type.rawName}': ${type.name}.parse");
      gen.writeln(type == types.last ? '' : ',');
    });
    gen.writeln('};');
    gen.writeln();
    gen.writeStatement('class VmService {');
    gen.writeStatement('StreamSubscription _streamSub;');
    gen.writeStatement('Function _writeMessage;');
    gen.writeStatement('int _id = 0;');
    gen.writeStatement('Map<String, Completer<Response>> _completers = {};');
    gen.writeStatement('Log _log;');
    gen.writeln('''

StreamController<String> _onSend = new StreamController.broadcast(sync: true);
StreamController<String> _onReceive = new StreamController.broadcast(sync: true);

Map<String, StreamController<Event>> _eventControllers = {};

StreamController<Event> _getEventController(String eventName) {
  StreamController<Event> controller = _eventControllers[eventName];
  if (controller == null) {
    controller = new StreamController.broadcast();
    _eventControllers[eventName] = controller;
  }
  return controller;
}

VmService(Stream<String> inStream, void writeMessage(String message), {Log log}) {
  _streamSub = inStream.listen(_processMessage);
  _writeMessage = writeMessage;
  _log = log == null ? new _NullLog() : log;
}

// VMUpdate
Stream<Event> get onVMEvent => _getEventController('VM').stream;

// IsolateStart, IsolateRunnable, IsolateExit, IsolateUpdate
Stream<Event> get onIsolateEvent => _getEventController('Isolate').stream;

// PauseStart, PauseExit, PauseBreakpoint, PauseInterrupted, PauseException,
// Resume, BreakpointAdded, BreakpointResolved, BreakpointRemoved, Inspect
Stream<Event> get onDebugEvent => _getEventController('Debug').stream;

// GC
Stream<Event> get onGCEvent => _getEventController('GC').stream;

// WriteEvent
Stream<Event> get onStdoutEvent => _getEventController('Stdout').stream;

// WriteEvent
Stream<Event> get onStderrEvent => _getEventController('Stderr').stream;

// Listen for a specific event name.
Stream<Event> onEvent(String streamName) => _getEventController(streamName).stream;

''');

    gen.writeln();
    methods.forEach((m) => m.generate(gen));
    gen.out(_implCode);
    gen.writeStatement('}');
    gen.writeln();
    gen.writeln(_rpcError);
    gen.writeln('// enums');
    enums.forEach((e) => e.generate(gen));
    gen.writeln();
    gen.writeln('// types');
    types.forEach((t) => t.generate(gen));
  }

  void setDefaultValue(String typeName, String fieldName, String defaultValue) {
    types.firstWhere((t) => t.name == typeName)
      .fields.firstWhere((f) => f.name == fieldName)
        .defaultValue = defaultValue;
  }

  bool isEnumName(String typeName) => enums.any((Enum e) => e.name == typeName);

  Type getType(String name) =>
      types.firstWhere((t) => t.name == name, orElse: () => null);
}

class Method extends Member {
  final String name;
  final String docs;

  MemberType returnType = new MemberType();
  List<MethodArg> args = [];

  Method(this.name, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  bool get hasArgs => args.isNotEmpty;

  bool get hasOptionalArgs => args.any((MethodArg arg) => arg.optional);

  void generate(DartGenerator gen) {
    gen.writeln();
    if (docs != null) {
      String _docs = docs == null ? '' : docs;
      if (returnType.isMultipleReturns) {
        _docs += '\n\nThe return value can be one of '
            '${joinLast(returnType.types.map((t) => '[${t}]'), ', ', ' or ')}.';
        _docs = _docs.trim();
      }
      if (_docs.isNotEmpty) gen.writeDocs(_docs);
      gen.write('Future<${returnType.name}> ${name}(');
      bool startedOptional = false;
      gen.write(args.map((MethodArg arg) {
        String typeName = api.isEnumName(arg.type) ? '/*${arg.type}*/ String' : arg.paramType;
        if (arg.optional && !startedOptional) {
          startedOptional = true;
          return '{${typeName} ${arg.name}';
        } else {
          return '${typeName} ${arg.name}';
        }
      }).join(', '));
      if (startedOptional) gen.write('}');
      gen.write(') ');
      if (!hasArgs) {
        gen.writeStatement("=> _call('${name}');");
      } else if (hasOptionalArgs) {
        gen.writeStatement('{');
        gen.write('Map m = {');
        gen.write(args.where((MethodArg a) => !a.optional).map(
            (arg) => "'${arg.name}': ${arg.name}").join(', '));
        gen.writeln('};');
        args.where((MethodArg a) => a.optional).forEach((MethodArg arg) {
          String valueRef = arg.name;
          gen.writeln("if (${arg.name} != null) m['${arg.name}'] = ${valueRef};");
        });
        gen.writeStatement("return _call('${name}', m);");
        gen.writeStatement('}');
      } else {
        gen.writeStatement('{');
        gen.write("return _call('${name}', {");
        gen.write(args.map((MethodArg arg) {
          return "'${arg.name}': ${arg.name}";
        }).join(', '));
        gen.writeStatement('});');
        gen.writeStatement('}');
      }
    }
  }

  void _parse(Token token) {
    new MethodParser(token).parseInto(this);
  }
}

class MemberType extends Member {
  List<TypeRef> types = [];

  MemberType();

  void parse(Parser parser) {
    // foo|bar[]|baz
    // (@Instance|Sentinel)[]
    bool loop = true;

    while (loop) {
      if (parser.consume('(')) {
        while (parser.peek().text != ')') {
          // @Instance | Sentinel
          parser.advance();
        }
        parser.consume(')');
        TypeRef ref = new TypeRef('dynamic');
        while (parser.consume('[')) {
          parser.expect(']');
          ref.arrayDepth++;
        }
        types.add(ref);
      } else {
        Token t = parser.expectName();
        TypeRef ref = new TypeRef(_coerceRefType(t.text));
        while (parser.consume('[')) {
          parser.expect(']');
          ref.arrayDepth++;
        }
        types.add(ref);
      }

      loop = parser.consume('|');
    }
  }

  String get name {
    if (types.isEmpty) return '';
    if (types.length == 1) return types.first.ref;
    return 'dynamic';
  }

  bool get isMultipleReturns => types.length > 1;

  bool get isSimple => types.length == 1 && types.first.isSimple;

  bool get isEnum => types.length == 1 && api.isEnumName(types.first.name);

  bool get isArray => types.length == 1 && types.first.isArray;

  void generate(DartGenerator gen) => gen.write(name);
}

class TypeRef {
  String name;
  int arrayDepth = 0;

  TypeRef(this.name);

  String get ref => arrayDepth == 2
      ? 'List<List<${name}>>' : arrayDepth == 1 ? 'List<${name}>' : name;

  bool get isArray => arrayDepth > 0;

  bool get isSimple => arrayDepth == 0 &&
      (name == 'int' || name == 'num' || name == 'String' || name == 'bool');

  String toString() => ref;
}

class MethodArg extends Member {
  final Method parent;
  String type;
  String name;
  bool optional = false;

  MethodArg(this.parent, this.type, this.name);

  String get paramType => type;

  void generate(DartGenerator gen) {
    gen.write('${type} ${name}');
  }
}

class Type extends Member {
  final Api parent;
  String rawName;
  String name;
  String superName;
  final String docs;
  List<TypeField> fields = [];

  Type(this.parent, String categoryName, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  bool get isResponse {
    if (superName == null) return false;
    if (name == 'Response' || superName == 'Response') return true;
    return parent.getType(superName).isResponse;
  }

  bool get isRef => name.endsWith('Ref');

  bool get supportsIdentity {
    if (fields.any((f) => f.name == 'id')) return true;
    return superName == null ? false : getSuper().supportsIdentity;
  }

  Type getSuper() => superName == null ? null : api.getType(superName);

  List<TypeField> getAllFields() {
    if (superName == null) return fields;

    List<TypeField> all = [];
    all.insertAll(0, fields);

    Type s = getSuper();
    while (s != null) {
      all.insertAll(0, s.fields);
      s = s.getSuper();
    }

    return all;
  }

  void generate(DartGenerator gen) {
    gen.writeln();
    if (docs != null) gen.writeDocs(docs);
    gen.write('class ${name} ');
    if (superName != null) gen.write('extends ${superName} ');
    gen.writeln('{');
    gen.writeln('static ${name} parse(Map json) => '
        'json == null ? null : new ${name}._fromJson(json);');
    gen.writeln();

    if (name == 'Response') {
      gen.writeln('Map<String, dynamic> json;');
    }

    // fields
    fields.forEach((TypeField field) => field.generate(gen));
    gen.writeln();

    // ctors
    gen.writeln('${name}();');
    gen.writeln();

    String superCall = superName == null ? '' : ": super._fromJson(json) ";
    if (name == 'Response') {
      gen.writeln('${name}._fromJson(this.json) {');
    } else {
      gen.writeln('${name}._fromJson(Map json) ${superCall}{');
    }

    fields.forEach((TypeField field) {
      if (field.type.isSimple || field.type.isEnum) {
        gen.write("${field.generatableName} = json['${field.name}']");
        if (field.defaultValue != null) {
          gen.write(' ?? ${field.defaultValue}');
        }
        gen.writeln(';');
      // } else if (field.type.isEnum) {
      //   // Parse the enum.
      //   String enumTypeName = field.type.types.first.name;
      //   gen.writeln(
      //     "${field.generatableName} = _parse${enumTypeName}[json['${field.name}']];");
      } else if (field.type.isArray) {
        TypeRef fieldType = field.type.types.first;
        gen.writeln("${field.generatableName} = _createObject(json['${field.name}']) "
            "as ${fieldType.ref};");
      } else {
        gen.writeln("${field.generatableName} = _createObject(json['${field.name}']);");
      }
    });
    gen.writeln('}');
    gen.writeln();

    // equals and hashCode
    if (supportsIdentity) {
      gen.writeStatement('int get hashCode => id.hashCode;');
      gen.writeln();

      gen.writeStatement('operator==(other) => other is ${name} && id == other.id;');
      gen.writeln();
    }

    // toString()
    Iterable<TypeField> toStringFields = getAllFields().where((f) => !f.optional);
    if (toStringFields.length <= 7) {
      String properties = toStringFields.map((TypeField f) =>
          "${f.generatableName}: \${${f.generatableName}}").join(', ');
      if (properties.length > 60) {
        int index = properties.indexOf(', ', 55);
        if (index != -1) {
          properties = properties.substring(0, index + 2) +
              "' //\n'" + properties.substring(index + 2);
        }
        gen.writeln("String toString() => '[${name} ' //\n'${properties}]';");
      } else {
        gen.writeln("String toString() => '[${name} ${properties}]';");
      }
    } else {
      gen.writeln("String toString() => '[${name}]';");
    }

    gen.writeln('}');
  }

  void _parse(Token token) {
    new TypeParser(token).parseInto(this);
  }
}

class TypeField extends Member {
  static final Map<String, String> _nameRemap = {
    'const': 'isConst',
    'final': 'isFinal',
    'static': 'isStatic',
    'abstract': 'isAbstract',
    'super': 'superClass',
    'class': 'classRef'
  };

  final Type parent;
  final String _docs;
  MemberType type = new MemberType();
  String name;
  bool optional = false;
  String defaultValue;

  TypeField(this.parent, this._docs);

  String get docs {
    String str = _docs == null ? '' : _docs;
    if (type.isMultipleReturns) {
      str += '\n\n[${generatableName}] can be one of '
          '${joinLast(type.types.map((t) => '[${t}]'), ', ', ' or ')}.';
      str = str.trim();
    }
    return str;
  }

  String get generatableName {
    return _nameRemap[name] != null ? _nameRemap[name] : name;
  }

  void generate(DartGenerator gen) {
    if (docs.isNotEmpty) gen.writeDocs(docs);
    if (optional) gen.write('@optional ');
    String typeName = api.isEnumName(type.name) ? '/*${type.name}*/ String' : type.name;
    gen.writeStatement('${typeName} ${generatableName};');
    if (parent.fields.any((field) => field.hasDocs)) gen.writeln();
  }
}

class Enum extends Member {
  final String name;
  final String docs;

  List<EnumValue> enums = [];

  Enum(this.name, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  String get prefix =>
    name.endsWith('Kind') ? name.substring(0, name.length - 4) : name;

  void generate(DartGenerator gen) {
    gen.writeln();
    if (docs != null) gen.writeDocs(docs);
    gen.writeStatement('class ${name} {');
    gen.writeStatement('${name}._();');
    gen.writeln();
    enums.forEach((e) => e.generate(gen));
    gen.writeStatement('}');
  }

  void _parse(Token token) {
    new EnumParser(token).parseInto(this);
  }
}

class EnumValue extends Member {
  final Enum parent;
  final String name;
  final String docs;

  EnumValue(this.parent, this.name, [this.docs]);

  bool get isLast => parent.enums.last == this;

  void generate(DartGenerator gen) {
    if (docs != null) gen.writeDocs(docs);
    gen.writeStatement("static const String k${name} = '${name}';");
  }
}

class TextOutputVisitor implements NodeVisitor {
  static String printText(Node node) {
    TextOutputVisitor visitor = new TextOutputVisitor();
    node.accept(visitor);
    return visitor.toString();
  }

  StringBuffer buf = new StringBuffer();
  bool _em = false;
  bool _href = false;
  bool _blockquote = false;

  TextOutputVisitor();

  bool visitElementBefore(Element element) {
    if (element.tag == 'em') {
      buf.write('`');
      _em = true;
    } else if (element.tag == 'p') {
      // Nothing to do.
    } else if (element.tag == 'blockquote') {
      buf.write('```\n');
      _blockquote = true;
    } else if (element.tag == 'a') {
      _href = true;
    } else {
      print('unknown tag: ${element.tag}');
      buf.write(renderToHtml([element]));
    }

    return true;
  }

  void visitText(Text text) {
    String t = text.text;
    if (_em) {
      t = _coerceRefType(t);
    } else  if (_href) {
      t = '[${_coerceRefType(t)}]';
    }

    if (_blockquote) {
      buf.write('${t}\n```');
    } else {
      buf.write(t);
    }
  }

  void visitElementAfter(Element element) {
    if (element.tag == 'p') {
      buf.write('\n\n');
    } else if (element.tag == 'a') {
      _href = false;
    } else if (element.tag == 'blockquote') {
      //buf.write('```\n');
      _blockquote = false;
    } else if (element.tag == 'em') {
      buf.write('`');
      _em = false;
    }
  }

  String toString() => buf.toString().trim();
}

// @Instance|@Error|Sentinel evaluate(
//     string isolateId,
//     string targetId [optional],
//     string expression)
class MethodParser extends Parser {
  MethodParser(Token startToken) : super(startToken);

  void parseInto(Method method) {
    // method is return type, name, (, args )
    // args is type name, [optional], comma

    method.returnType.parse(this);

    Token t = expectName();
    validate(t.text == method.name, 'method name ${method.name} equals ${t.text}');

    expect('(');

    while (peek().text != ')') {
      Token type = expectName();
      Token name = expectName();
      MethodArg arg = new MethodArg(method, _coerceRefType(type.text), name.text);
      if (consume('[')) {
        expect('optional');
        expect(']');
        arg.optional = true;
      }
      method.args.add(arg);
      consume(',');
    }

    expect(')');

    method.args.sort((MethodArg a, MethodArg b) {
      if (!a.optional && b.optional) return -1;
      if (a.optional && !b.optional) return 1;
      return 0;
    });
  }
}

class TypeParser extends Parser {
  TypeParser(Token startToken) : super(startToken);

  void parseInto(Type type) {
    // class ClassList extends Response {
    //   // Docs here.
    //   @Class[] classes [optional];
    // }
    expect('class');

    Token t = expectName();
    type.rawName = t.text;
    type.name = _coerceRefType(type.rawName);
    if (consume('extends')) {
      t = expectName();
      type.superName = _coerceRefType(t.text);
    }

    expect('{');

    while (peek().text != '}') {
      TypeField field = new TypeField(type, collectComments());
      field.type.parse(this);
      field.name = expectName().text;
      if (consume('[')) {
        expect('optional');
        expect(']');
        field.optional = true;
      }
      type.fields.add(field);
      expect(';');
    }

    expect('}');
  }
}

class EnumParser extends Parser {
  EnumParser(Token startToken) : super(startToken);

  void parseInto(Enum e) {
    // enum ErrorKind { UnhandledException, Foo, Bar }
    // enum name { (comment* name ,)+ }
    expect('enum');

    Token t = expectName();
    validate(t.text == e.name, 'enum name ${e.name} equals ${t.text}');
    expect('{');

    while (!t.eof) {
      if (consume('}')) break;
      String docs = collectComments();
      t = expectName();
      consume(',');

      e.enums.add(new EnumValue(e, t.text, docs));
    }
  }
}
