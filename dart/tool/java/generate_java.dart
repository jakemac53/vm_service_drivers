// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library generate_vm_service_lib_java;

import 'package:markdown/markdown.dart';
import 'package:pub_semver/pub_semver.dart';

import '../common/generate_common.dart';
import '../common/parser.dart';
import '../common/src_gen_common.dart';
import 'src_gen_java.dart';

export 'src_gen_java.dart' show JavaGenerator;

const String servicePackage = 'org.dartlang.vm.service';

const List<String> simpleTypes = const [
  'BigDecimal',
  'boolean',
  'int',
  'String',
  'double'
];

const vmServiceJavadoc = '''
{@link VmService} allows control of and access to information in a running
Dart VM instance.
<br/>
Launch the Dart VM with the arguments:
<pre>
--pause_isolates_on_start
--observe
--enable-vm-service=some-port
</pre>
where <strong>some-port</strong> is a port number of your choice
which this client will use to communicate with the Dart VM.
See https://www.dartlang.org/tools/dart-vm/ for more details.
Once the VM is running, instantiate a new {@link VmService}
to connect to that VM via {@link VmService#connect(String)}
or {@link VmService#localConnect(int)}.
<br/>
{@link VmService} is not thread safe and should only be accessed from
a single thread. In addition, a given VM should only be accessed from
a single instance of {@link VmService}.
<br/>
Calls to {@link VmService} should not be nested.
More specifically, you should not make any calls to {@link VmService}
from within any {@link Consumer} method.
''';

Api api;

/// Convert documentation references
/// from spec style of [className] to javadoc style {@link className}
String convertDocLinks(String doc) {
  if (doc == null) return null;
  var sb = new StringBuffer();
  int start = 0;
  int end = doc.indexOf('[');
  while (end != -1) {
    sb.write(doc.substring(start, end));
    start = end;
    end = doc.indexOf(']', start);
    if (end == -1) break;
    if (end == start + 1) {
      sb.write('[]');
    } else {
      sb.write('{@link ');
      sb.write(doc.substring(start + 1, end));
      sb.write('}');
    }
    start = end + 1;
    end = doc.indexOf('[', start);
  }
  sb.write(doc.substring(start));
  return sb.toString();
}

String _coerceRefType(String typeName) {
  if (typeName == 'Class') typeName = 'ClassObj';
  if (typeName == 'Error') typeName = 'ErrorObj';
  if (typeName == 'Object') typeName = 'Obj';
  if (typeName == '@Object') typeName = 'ObjRef';
  if (typeName == 'Function') typeName = 'Func';
  if (typeName == '@Function') typeName = 'FuncRef';
  if (typeName.startsWith('@')) typeName = typeName.substring(1) + 'Ref';
  if (typeName == 'string') typeName = 'String';
  if (typeName == 'bool') typeName = 'boolean';
  if (typeName == 'num') typeName = 'BigDecimal';
  if (typeName == 'map') typeName = 'Map';
  return typeName;
}

class Api extends Member with ApiParseUtil {
  int serviceMajor;
  int serviceMinor;
  String serviceVersion;
  List<Method> methods = [];
  List<Enum> enums = [];
  List<Type> types = [];
  Map<String, List<String>> streamIdMap = {};

  String get docs => null;

  String get name => 'api';

  void addProperty(String typeName, String propertyName, {String javadoc}) {
    var t = types.firstWhere((t) => t.name == typeName);
    for (var f in t.fields) {
      if (f.name == propertyName) {
        print('$typeName already has $propertyName field');
        return;
      }
    }
    var f = new TypeField(t, javadoc);
    f.name = propertyName;
    f.type = new MemberType();
    f.type.types = [new TypeRef('String')];
    t.fields.add(f);
    print('added $propertyName field to $typeName');
  }

  void generate(JavaGenerator gen) {
    _setFileHeader();

    // Set default value for unspecified property
    setDefaultValue('Instance', 'valueAsStringIsTruncated');
    setDefaultValue('InstanceRef', 'valueAsStringIsTruncated');

    // Hack to populate method argument docs
    for (var m in methods) {
      for (var a in m.args) {
        if (a.hasDocs) continue;
        var t = types.firstWhere((Type t) => t.name == a.type.name,
            orElse: () => null);
        if (t != null) {
          a.docs = t.docs;
          continue;
        }
        var e = enums.firstWhere((Enum e) => e.name == a.type.name,
            orElse: () => null);
        if (e != null) {
          a.docs = e.docs;
          continue;
        }
      }
    }

    gen.writeType('$servicePackage.VmService', (TypeWriter writer) {
      writer.addImport('com.google.gson.JsonArray');
      writer.addImport('com.google.gson.JsonObject');
      writer.addImport('com.google.gson.JsonPrimitive');
      writer.addImport('java.util.List');

      writer.addImport('$servicePackage.consumer.*');
      writer.addImport('$servicePackage.element.*');
      writer.javadoc = vmServiceJavadoc;
      writer.superclassName = '$servicePackage.VmServiceBase';

      for (String streamId in streamIdMap.keys.toList()..sort()) {
        String alias = streamId.toUpperCase();
        while (alias.startsWith('_')) {
          alias = alias.substring(1);
        }
        writer.addField('${alias}_STREAM_ID', 'String',
            modifiers: 'public static final', value: '"$streamId"');
      }

      writer.addField('versionMajor', 'int',
          modifiers: 'public static final',
          value: '$serviceMajor',
          javadoc:
              'The major version number of the protocol supported by this client.');
      writer.addField('versionMinor', 'int',
          modifiers: 'public static final',
          value: '$serviceMinor',
          javadoc:
              'The minor version number of the protocol supported by this client.');
      for (var m in methods) {
        m.generateVmServiceMethod(writer);
        if (m.hasOptionalArgs) {
          m.generateVmServiceMethod(writer, includeOptional: true);
        }
      }

      writer.addMethod('forwardResponse', [
        new JavaMethodArg('consumer', 'Consumer'),
        new JavaMethodArg('responseType', 'String'),
        new JavaMethodArg('json', 'JsonObject')
      ], (StatementWriter writer) {
        var generatedForwards = new Set<String>();

        var sorted = methods.toList()
          ..sort((m1, m2) {
            return m1.consumerTypeName.compareTo(m2.consumerTypeName);
          });
        for (var m in sorted) {
          if (generatedForwards.add(m.consumerTypeName)) {
            m.generateVmServiceForward(writer);
          }
        }
        writer.addLine('if (consumer instanceof ServiceExtensionConsumer) {');
        writer
            .addLine('  ((ServiceExtensionConsumer) consumer).received(json);');
        writer.addLine('  return;');
        writer.addLine('}');
        writer.addLine('logUnknownResponse(consumer, json);');
      }, modifiers: null, isOverride: true);

      writer.addMethod("convertMapToJsonObject", [
        new JavaMethodArg('map', 'Map<String, String>')
      ], (StatementWriter writer) {
        writer.addLine('JsonObject obj = new JsonObject();');
        writer.addLine('for (String key : map.keySet()) {');
        writer.addLine('  obj.addProperty(key, map.get(key));');
        writer.addLine('}');
        writer.addLine('return obj;');
      }, modifiers: "private", returnType: "JsonObject");

      writer.addMethod(
          "convertIterableToJsonArray", [new JavaMethodArg('list', 'Iterable')],
          (StatementWriter writer) {
        writer.addLine('JsonArray arr = new JsonArray();');
        writer.addLine('for (Object element : list) {');
        writer.addLine('  arr.add(new JsonPrimitive(element.toString()));');
        writer.addLine('}');
        writer.addLine('return arr;');
      }, modifiers: "private", returnType: "JsonArray");
    });

    for (var m in methods) {
      m.generateConsumerInterface(gen);
    }
    for (var t in types) {
      t.generateElement(gen);
    }
    for (var e in enums) {
      e.generateEnum(gen);
    }
  }

  void _mergeTypes() {
    final Map<String, Type> map = <String, Type>{};
    for (Type t in types) {
      if (map.containsKey(t.name)) {
        map[t.name] = new Type.merge(map[t.name], t);
      } else {
        map[t.name] = t;
      }
    }
    types = map.values.toList();
  }

  void _mergeEnums() {
    final Map<String, Enum> map = <String, Enum>{};
    for (Enum e in enums) {
      if (map.containsKey(e.name)) {
        map[e.name] = new Enum.merge(map[e.name], e);
      } else {
        map[e.name] = e;
      }
    }
    enums = map.values.toList();
  }

  Type getType(String name) =>
      types.firstWhere((t) => t.name == name, orElse: () => null);

  bool isEnumName(String typeName) => enums.any((Enum e) => e.name == typeName);

  void parse(List<Node> nodes) {
    Version version = ApiParseUtil.parseVersionSemVer(nodes);
    serviceMajor = version.major;
    serviceMinor = version.minor;
    serviceVersion = '$serviceMajor.$serviceMinor';

    // Look for h3 nodes
    // the pre following it is the definition
    // the optional p following that is the documentation

    String h3Name;

    for (int i = 0; i < nodes.length; i++) {
      Node node = nodes[i];

      if (isPre(node) && h3Name != null) {
        String definition = textForCode(node);
        String docs;

        if (i + 1 < nodes.length && isPara(nodes[i + 1])) {
          Element p = nodes[++i];
          docs = collapseWhitespace(TextOutputVisitor.printText(p));
        }

        _parse(h3Name, definition, docs);
      } else if (isH3(node)) {
        h3Name = textForElement(node);
      } else if (isHeader(node)) {
        h3Name = null;
      } else if (isPara(node)) {
        var children = (node as Element).children;
        if (children.isNotEmpty && children.first is Text) {
          var text = children.expand<String>((child) {
            if (child is Text) return [child.text];
            return [];
          }).join();
          if (text.startsWith('streamId |')) {
            _parseStreamIds(text);
          }
        }
      }
    }
    // We merge Types and Enums with the same name.
    // The service.md file contains the public definition of Types and Enums.
    // The service_undocumented.md potentially contains overloaded definitions
    // of Types and Enums from the public definition with extra Type fields
    // or Enum values.
    _mergeTypes();
    _mergeEnums();
  }

  void setDefaultValue(String typeName, String propertyName) {
    var type = types.firstWhere((t) => t.name == typeName);
    var field = type.fields.firstWhere((f) => f.name == propertyName);
    field.defaultValue = 'false';
  }

  void _parse(String name, String definition, [String docs]) {
    name = name.trim();
    definition = definition.trim();
    // clean markdown introduced changes
    definition = definition.replaceAll('&lt;', '<').replaceAll('&gt;', '>');
    if (docs != null) docs = docs.trim();

    if (definition.startsWith('class ')) {
      types.add(new Type(this, name, definition, docs));
    } else if (name.substring(0, 1).toLowerCase() == name.substring(0, 1)) {
      methods.add(new Method(name, definition, docs));
    } else if (definition.startsWith('enum ')) {
      enums.add(new Enum(name, definition, docs));
    } else {
      throw 'unexpected entity: ${name}, ${definition}';
    }
  }

  void _parseStreamIds(String text) {
    for (String line in text.split('\n')) {
      if (line.startsWith('streamId |')) continue;
      if (line.startsWith('---')) continue;
      var index = line.indexOf('|');
      var streamId = line.substring(0, index).trim();
      List<String> eventTypes = new List.from(
          line.substring(index + 1).split(',').map((t) => t.trim()));
      eventTypes.sort();
      streamIdMap[streamId] = eventTypes;
    }
  }

  void _setFileHeader() {
    fileHeader = r'''/*
 * Copyright (c) 2015, the Dart project authors.
 *
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
''';
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
}

class Enum extends Member {
  final String name;
  final String docs;

  List<EnumValue> enums = [];

  Enum(this.name, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  Enum._(this.name, this.docs);

  factory Enum.merge(Enum e1, Enum e2) {
    final String name = e1.name;
    final String docs = [e1.docs, e2.docs].where((e) => e != null).join('\n');
    final Map<String, EnumValue> enums = <String, EnumValue>{};
    for (EnumValue e in e2.enums) {
      enums[e.name] = e;
    }
    // The official service.md is the default
    for (EnumValue e in e1.enums) {
      enums[e.name] = e;
    }

    return new Enum._(name, docs)..enums = enums.values.toList();
  }

  String get elementTypeName => '$servicePackage.element.$name';

  void generateEnum(JavaGenerator gen) {
    gen.writeType(elementTypeName, (TypeWriter writer) {
      writer.javadoc = convertDocLinks(docs);
      writer.isEnum = true;
      enums.sort((v1, v2) => v1.name.compareTo(v2.name));
      for (var value in enums) {
        writer.addEnumValue(value.name, javadoc: value.docs);
      }
      writer.addEnumValue('Unknown',
          javadoc: 'Represents a value returned by the VM'
              ' but unknown to this client.',
          isLast: true);
    });
  }

  void _parse(Token token) {
    new EnumParser(token).parseInto(this);
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

class EnumValue extends Member {
  final Enum parent;
  final String name;
  final String docs;

  EnumValue(this.parent, this.name, [this.docs]);

  bool get isLast => parent.enums.last == this;
}

abstract class Member {
  String get docs => null;

  bool get hasDocs => docs != null;

  String get name;

  String toString() => name;
}

class MemberType extends Member {
  List<TypeRef> types = [];

  MemberType();

  bool get hasSentinel => types.any((t) => t.name == 'Sentinel');

  bool get isEnum => types.length == 1 && api.isEnumName(types.first.name);

  bool get isMultipleReturns => types.length > 1;

  bool get isSimple => types.length == 1 && types.first.isSimple;

  bool get isValueAndSentinel => types.length == 2 && hasSentinel;

  String get name {
    if (types.isEmpty) return '';
    if (types.length == 1) return types.first.ref;
    return 'dynamic';
  }

  TypeRef get valueType {
    if (types.length == 1) return types.first;
    if (isValueAndSentinel) {
      return types.firstWhere((t) => t.name != 'Sentinel');
    }
    return null;
  }

  void parse(Parser parser) {
    // foo|bar[]|baz
    // (@Instance|Sentinel)[]
    bool loop = true;
    bool isMulti = false;

    while (loop) {
      parser.consume('(');
      Token t = parser.expectName();
      if (parser.consume(')')) isMulti = true;
      TypeRef ref = new TypeRef(_coerceRefType(t.text));
      types.add(ref);

      while (parser.consume('[')) {
        parser.expect(']');
        if (isMulti) {
          types.forEach((t) => t.arrayDepth++);
        } else {
          ref.arrayDepth++;
        }
      }

      loop = parser.consume('|');
    }
  }
}

class Method extends Member {
  final String name;
  final String docs;

  MemberType returnType = new MemberType();
  List<MethodArg> args = [];

  Method(this.name, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  bool get isUndocumented => name.startsWith('_');

  String get publicName => isUndocumented ? name.substring(1) : name;

  String get consumerTypeName {
    String prefix;
    if (returnType.isMultipleReturns) {
      prefix = titleCase(name);
    } else {
      prefix = returnType.types.first.javaBoxedName;
    }
    return '$servicePackage.consumer.${prefix}Consumer';
  }

  bool get hasArgs => args.isNotEmpty;

  bool get hasOptionalArgs => args.any((MethodArg arg) => arg.optional);

  void generateConsumerInterface(JavaGenerator gen) {
    gen.writeType(consumerTypeName, (TypeWriter writer) {
      writer.javadoc = convertDocLinks(returnType.docs);
      writer.interfaceNames.add('$servicePackage.consumer.Consumer');
      writer.isInterface = true;
      for (var t in returnType.types) {
        writer.addImport(t.elementTypeName);
        writer.addMethod("received",
            [new JavaMethodArg('response', t.elementTypeName)], null);
      }
    });
  }

  void generateVmServiceForward(StatementWriter writer) {
    var consumerName = classNameFor(consumerTypeName);
    writer.addLine('if (consumer instanceof $consumerName) {');
    List<Type> types = new List.from(returnType.types.map((ref) => ref.type));
    for (int index = 0; index < types.length; ++index) {
      types.addAll(types[index].subtypes);
    }
    types.sort((t1, t2) => t1.name.compareTo(t2.name));
    for (var t in types) {
      var responseName = classNameFor(t.elementTypeName);
      writer.addLine('  if (responseType.equals("${t.rawName}")) {');
      writer.addLine(
          '    (($consumerName) consumer).received(new $responseName(json));');
      writer.addLine('    return;');
      writer.addLine('  }');
    }
    writer.addLine('}');
  }

  void generateVmServiceMethod(TypeWriter writer, {includeOptional = false}) {
    // TODO(danrubel) move this to the Consumer's javadoc
//    String javadoc = docs == null ? '' : docs;
//    if (returnType.isMultipleReturns) {
//      javadoc += '\n\nThe return value can be one of '
//          '${joinLast(returnType.types.map((t) => '[${t}]'), ', ', ' or ')}.';
//      javadoc = javadoc.trim();
//    }

    // Update method docs
    var javadoc = new StringBuffer(docs == null ? '' : docs);
    bool firstParamDoc = true;
    if (isUndocumented) {
      if (docs != null) {
        javadoc.writeln();
      }
      javadoc.writeln();
      javadoc.writeln('@undocumented');
    }
    for (var a in args) {
      if (!includeOptional && a.optional) continue;
      var paramDoc = new StringBuffer(a.docs ?? '');
      if (paramDoc.isEmpty) {}
      if (a.optional) {
        if (paramDoc.isNotEmpty) paramDoc.write(' ');
        paramDoc.write('This parameter is optional and may be null.');
      }
      if (paramDoc.isNotEmpty) {
        if (firstParamDoc) {
          javadoc.writeln();
          firstParamDoc = false;
        }
        javadoc.writeln('@param ${a.name} $paramDoc');
      }
    }

    if (args.any((MethodArg arg) => (arg.type.name == 'Map'))) {
      writer.addImport('java.util.Map');
    }

    List<MethodArg> mthArgs = args;
    if (!includeOptional) {
      mthArgs = mthArgs.toList()..removeWhere((a) => a.optional);
    }

    List<JavaMethodArg> javaMethodArgs =
        new List.from(mthArgs.map((a) => a.asJavaMethodArg));
    javaMethodArgs
        .add(new JavaMethodArg('consumer', classNameFor(consumerTypeName)));
    writer.addMethod(publicName, javaMethodArgs, (StatementWriter writer) {
      writer.addLine('JsonObject params = new JsonObject();');
      for (MethodArg arg in args) {
        if (!includeOptional && arg.optional) continue;
        var name = arg.name;
        String op = arg.optional ? 'if (${name} != null) ' : '';
        if (arg.isEnumType) {
          writer.addLine('${op}params.addProperty("$name", $name.name());');
        } else if (arg.type.name == 'Map') {
          writer.addLine(
              '${op}params.add("$name", convertMapToJsonObject($name));');
        } else if (arg.type.arrayDepth > 0) {
          writer.addLine(
              '${op}params.add("$name", convertIterableToJsonArray($name));');
        } else {
          writer.addLine('${op}params.addProperty("$name", $name);');
        }
      }
      writer.addLine('request("$name", params, consumer);');
    }, javadoc: javadoc.toString());
  }

  void _parse(Token token) {
    new MethodParser(token).parseInto(this);
  }
}

class MethodArg extends Member {
  final Method parent;
  final TypeRef type;
  String name;
  String docs;
  bool optional = false;

  MethodArg(this.parent, this.type, this.name);

  get asJavaMethodArg {
    if (optional && type.ref == 'int') {
      return new JavaMethodArg(name, 'Integer');
    }
    if (optional && type.ref == 'double') {
      return new JavaMethodArg(name, 'Double');
    }
    if (optional && type.ref == 'boolean') {
      return new JavaMethodArg(name, 'Boolean');
    }
    return new JavaMethodArg(name, type.ref);
  }

  /// TODO: Hacked enum arg type determination
  bool get isEnumType => name == 'step' || name == 'mode';
}

class MethodParser extends Parser {
  MethodParser(Token startToken) : super(startToken);

  void parseInto(Method method) {
    // method is return type, name, (, args )
    // args is type name, [optional], comma

    method.returnType.parse(this);

    Token t = expectName();
    validate(
        t.text == method.name, 'method name ${method.name} equals ${t.text}');

    expect('(');

    while (peek().text != ')') {
      Token type = expectName();
      TypeRef ref = new TypeRef(_coerceRefType(type.text));
      if (peek().text == '[') {
        while (consume('[')) {
          expect(']');
          ref.arrayDepth++;
        }
      } else if (peek().text == '<') {
        // handle generics
        expect('<');
        ref.genericTypes = [];
        while (peek().text != '>') {
          Token genericTypeName = expectName();
          ref.genericTypes
              .add(new TypeRef(_coerceRefType(genericTypeName.text)));
          consume(',');
        }
        expect('>');
      }
      Token name = expectName();
      MethodArg arg = new MethodArg(method, ref, name.text);
      if (consume('[')) {
        expect('optional');
        expect(']');
        arg.optional = true;
      }
      method.args.add(arg);
      consume(',');
    }

    expect(')');
  }
}

class TextOutputVisitor implements NodeVisitor {
  StringBuffer buf = new StringBuffer();

  bool _inRef = false;

  TextOutputVisitor();

  String toString() => buf.toString().trim();

  void visitElementAfter(Element element) {
    if (element.tag == 'p') {
      buf.write('\n\n');
    } else if (element.tag == 'em') {
      buf.write(']');
      _inRef = false;
    }
  }

  bool visitElementBefore(Element element) {
    if (element.tag == 'em') {
      buf.write('[');
      _inRef = true;
    } else if (element.tag == 'p') {
      // Nothing to do.
    } else if (element.tag == 'a') {
      // Nothing to do - we're not writing out <a> refs (they won't resolve).
    } else {
      print('unknown tag: ${element.tag}');
      buf.write(renderToHtml([element]));
    }

    return true;
  }

  void visitText(Text text) {
    String t = text.text;
    if (_inRef) t = _coerceRefType(t);
    buf.write(t);
  }

  static String printText(Node node) {
    TextOutputVisitor visitor = new TextOutputVisitor();
    node.accept(visitor);
    return visitor.toString();
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

  Type._(this.parent, this.rawName, this.name, this.superName, this.docs);

  factory Type.merge(Type t1, Type t2) {
    final Api parent = t1.parent;
    final String rawName = t1.rawName;
    final String name = t1.name;
    final String superName = t1.superName;
    final String docs = [t1.docs, t2.docs].where((e) => e != null).join('\n');
    final Map<String, TypeField> fields = <String, TypeField>{};
    for (TypeField f in t2.fields) {
      fields[f.name] = f;
    }
    // The official service.md is the default
    for (TypeField f in t1.fields) {
      fields[f.name] = f;
    }

    return new Type._(parent, rawName, name, superName, docs)
      ..fields = fields.values.toList();
  }

  String get elementTypeName {
    if (isSimple) return null;
    return '$servicePackage.element.$name';
  }

  bool get isRef => name.endsWith('Ref');

  bool get isResponse {
    if (superName == null) return false;
    if (name == 'Response' || superName == 'Response') return true;
    return parent.getType(superName).isResponse;
  }

  bool get isSimple => simpleTypes.contains(name);

  bool get isUndocumented => name.startsWith('_');

  String get publicName => isUndocumented ? name.substring(1) : name;

  get jsonTypeName {
    if (name == 'ClassObj') return 'Class';
    if (name == 'ErrorObj') return 'Error';
    return name;
  }

  Iterable<Type> get subtypes =>
      api.types.toList()..retainWhere((t) => t.superName == name);

  void generateElement(JavaGenerator gen) {
    gen.writeType('$servicePackage.element.$publicName', (TypeWriter writer) {
      if (fields.any((f) => f.type.types.any((t) => t.isArray))) {
        writer.addImport('com.google.gson.JsonObject');
      }
      writer.addImport('com.google.gson.JsonObject');
      writer.javadoc = convertDocLinks(docs);
      writer.superclassName = superName ?? 'Element';
      writer.addConstructor(<JavaMethodArg>[
        new JavaMethodArg('json', 'com.google.gson.JsonObject')
      ], (StatementWriter writer) {
        writer.addLine('super(json);');
      });

      for (var field in fields) {
        field.generateAccessor(writer);
      }
    });
  }

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

  Type getSuper() => superName == null ? null : api.getType(superName);

  void _parse(Token token) {
    new TypeParser(token).parseInto(this);
  }
}

// @Instance|@Error|Sentinel evaluate(
//     string isolateId,
//     string targetId [optional],
//     string expression)
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

  String get accessorName {
    var remappedName = _nameRemap[name];
    if (remappedName != null) {
      if (remappedName.startsWith('is')) return remappedName;
    } else {
      remappedName = name;
    }
    return 'get${titleCase(remappedName)}';
  }

  String get docs {
    String str = _docs == null ? '' : _docs;
    if (type.isMultipleReturns) {
      str += '\n\n@return one of '
          '${joinLast(type.types.map((t) => '<code>${t}</code>'), ', ', ' or ')}';
      str = str.trim();
    }
    if (optional) {
      str += '\n\nCan return <code>null</code>.';
      str = str.trim();
    }
    return str;
  }

  void generateAccessor(TypeWriter writer) {
    if (type.isMultipleReturns && !type.isValueAndSentinel) {
      writer.addMethod(accessorName, [], (StatementWriter w) {
        w.addImport('com.google.gson.JsonObject');
        w.addLine('JsonObject elem = (JsonObject)json.get("$name");');
        w.addLine('if (elem == null) return null;\n');
        for (TypeRef t in type.types) {
          String refName = t.name;
          if (refName.endsWith('Ref')) {
            refName = "@" + refName.substring(0, refName.length - 3);
          }
          w.addLine('if (elem.get("type").getAsString().equals("${refName}")) '
              'return new ${t.name}(elem);');
        }
        w.addLine('return null;');
      }, javadoc: docs, returnType: 'Object');
    } else {
      String returnType = type.valueType.ref;
      if (name == 'timestamp') {
        returnType = 'long';
      }

      writer.addMethod(accessorName, [], (StatementWriter writer) {
        type.valueType.generateAccessStatements(writer, name,
            canBeSentinel: type.isValueAndSentinel,
            defaultValue: defaultValue,
            optional: optional);
      }, javadoc: docs, returnType: returnType);
    }
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

class TypeRef {
  String name;
  int arrayDepth = 0;
  List<TypeRef> genericTypes;

  TypeRef(this.name);

  String get elementTypeName {
    if (isSimple) return null;
    return '$servicePackage.element.$publicName';
  }

  bool get isArray => arrayDepth > 0;

  /// Hacked enum determination
  bool get isEnum => name.endsWith('Kind') || name.endsWith('Mode');

  bool get isSimple => simpleTypes.contains(name);

  bool get isUndocumented => name.startsWith('_');

  String get publicName => isUndocumented ? name.substring(1) : name;

  String get javaBoxedName {
    if (name == 'boolean') return 'Boolean';
    if (name == 'int') return 'Integer';
    if (name == 'double') return 'Double';
    return publicName;
  }

  String get ref {
    if (genericTypes != null) {
      return '$name<${genericTypes.join(', ')}>';
    } else if (isSimple) {
      if (arrayDepth == 2) return 'List<List<${javaBoxedName}>>';
      if (arrayDepth == 1) return 'List<${javaBoxedName}>';
    } else {
      if (arrayDepth == 2) return 'ElementList<ElementList<${javaBoxedName}>>';
      if (arrayDepth == 1) return 'ElementList<${javaBoxedName}>';
    }
    return name;
  }

  Type get type => api.types.firstWhere((t) => t.name == name);

  void generateAccessStatements(StatementWriter writer, String propertyName,
      {bool canBeSentinel = false, String defaultValue, bool optional = false}) {
    if (name == 'boolean') {
      if (isArray) {
        print('skipped accessor body for $propertyName');
      } else {
        if (defaultValue != null) {
          writer.addImport('com.google.gson.JsonElement');
          writer.addLine('JsonElement elem = json.get("$propertyName");');
          writer.addLine(
              'return elem != null ? elem.getAsBoolean() : $defaultValue;');
        } else if (optional) {
          writer.addLine('return json.get("$propertyName") == null ? '
              'false : json.get("$propertyName").getAsBoolean();');
        } else {
          writer.addLine('return json.get("$propertyName").getAsBoolean();');
        }
      }
    } else if (name == 'int') {
      if (arrayDepth > 1) {
        writer.addImport('java.util.List');
        writer.addLine('return getListListInt("$propertyName");');
      } else if (arrayDepth == 1) {
        writer.addImport('java.util.List');
        writer.addLine('return getListInt("$propertyName");');
      } else {
        if (propertyName == 'timestamp') {
          writer.addLine('return json.get("$propertyName") == null ? '
              '-1 : json.get("$propertyName").getAsLong();');
        } else {
          writer.addLine('return json.get("$propertyName") == null ? '
              '-1 : json.get("$propertyName").getAsInt();');
        }
      }
    } else if (name == 'double') {
      writer.addLine('return json.get("$propertyName") == null ? '
          '0.0 : json.get("$propertyName").getAsDouble();');
    } else if (name == 'BigDecimal') {
      if (isArray) {
        print('skipped accessor body for $propertyName');
      } else {
        writer.addImport('java.math.BigDecimal');
        writer.addLine('return json.get("$propertyName").getAsBigDecimal();');
      }
    } else if (name == 'String') {
      if (isArray) {
        writer.addImport('java.util.List');
        if (optional) {
          writer.addLine('return json.get("$propertyName") == null ? '
              'null : getListString("$propertyName");');
        } else {
          writer.addLine('return getListString("$propertyName");');
        }
      } else if (optional) {
        writer.addLine('return json.get("$propertyName") == null ? '
            'null : json.get("$propertyName").getAsString();');
      } else {
        writer.addLine('return json.get("$propertyName").getAsString();');
      }
    } else if (isEnum) {
      if (isArray) {
        print('skipped accessor body for $propertyName');
      } else {
        if (optional) {
          writer.addLine('if (json.get("$propertyName") == null) return null;');
          writer.addLine('');
        }
        writer.addImport('com.google.gson.JsonElement');
        writer.addLine('JsonElement value = json.get("$propertyName");');
        writer.addLine('try {');
        writer.addLine('  return value == null ? $name.Unknown'
            ' : $name.valueOf(value.getAsString());');
        writer.addLine('} catch (IllegalArgumentException e) {');
        writer.addLine('  return $name.Unknown;');
        writer.addLine('}');
      }
    } else {
      if (arrayDepth > 1) {
        print('skipped accessor body for $propertyName');
      } else if (arrayDepth == 1) {
        writer.addImport('com.google.gson.JsonArray');
        if (optional) {
          writer.addLine('if (json.get("$propertyName") == null) return null;');
          writer.addLine('');
        }
        writer.addLine(
            'return new ElementList<$javaBoxedName>(json.get("$propertyName").getAsJsonArray()) {');
        writer.addLine('  @Override');
        writer.addLine(
            '  protected $javaBoxedName basicGet(JsonArray array, int index) {');
        writer.addLine(
            '    return new $javaBoxedName(array.get(index).getAsJsonObject());');
        writer.addLine('  }');
        writer.addLine('};');
      } else {
        if (canBeSentinel) {
          writer.addImport('com.google.gson.JsonElement');
          writer.addLine('JsonElement elem = json.get("$propertyName");');
          writer.addLine('if (!elem.isJsonObject()) return null;');
          writer.addLine('JsonObject child = elem.getAsJsonObject();');
          writer.addLine('String type = child.get("type").getAsString();');
          writer.addLine('if ("Sentinel".equals(type)) return null;');
          writer.addLine('return new $name(child);');
        } else {
          if (optional) {
            writer.addLine('return json.get("$propertyName") == null ? '
                'null : new $name((JsonObject) json.get("$propertyName"));');
          } else {
            writer.addLine(
                'return new $name((JsonObject) json.get("$propertyName"));');
          }
        }
      }
    }
  }

  String toString() => ref;
}
