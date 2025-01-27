import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_treeview/flutter_treeview.dart';
import 'package:isar/isar.dart';

import 'package:isar_inspector/common.dart';
import 'package:isar_inspector/edit_popup.dart';
import 'package:isar_inspector/prev_next.dart';
import 'package:isar_inspector/query_builder.dart';
import 'package:isar_inspector/schema.dart';
import 'package:isar_inspector/state/collections_state.dart';
import 'package:isar_inspector/state/instances_state.dart';
import 'package:isar_inspector/state/isar_connect_state_notifier.dart';
import 'package:isar_inspector/state/query_state.dart';

const _stringColor = Color(0xFF6A8759);
const _numberColor = Color(0xFF6897BB);
const _boolColor = Color(0xFFCC7832);
const _dateColor = Color(0xFFFFC66D);
const _disableColor = Colors.grey;

typedef Editor = void Function(ConnectEdit edit, EditorType type);
typedef Aggregate = Future<num?> Function(String property, AggregationOp op);

enum EditorType { add, edit, remove }

class QueryTable extends ConsumerWidget {
  const QueryTable({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(selectedCollectionPod).value!;
    final queryResults = ref.watch(queryResultsPod).value;

    if (queryResults == null ||
        queryResults.objects.isEmpty ||
        queryResults.collectionName != collection.name) {
      return Container();
    }

    final objects = queryResults.objects;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView.separated(
            primary: true,
            itemCount: objects.length,
            itemBuilder: (context, index) {
              return Stack(
                children: [
                  TableBlock(
                    key: ValueKey(
                      '${collection.name}'
                      '_${objects[index].getValue(collection.idName)}',
                    ),
                    collection: collection,
                    object: objects[index],
                    editor: (ConnectEdit edit, type) {
                      edit = edit.copyWith(
                        instance: ref.read(selectedInstancePod).value,
                        collection:
                            edit.collection == '' ? collection.name : null,
                      );

                      final pod = ref.read(isarConnectPod.notifier);
                      switch (type) {
                        case EditorType.add:
                          pod.addInList(edit);
                          break;

                        case EditorType.edit:
                          pod.editProperty(edit);
                          break;

                        case EditorType.remove:
                          pod.removeFromList(edit);
                          break;
                      }
                    },
                    aggregate: (property, op) async {
                      final query = ConnectQuery(
                        instance: ref.read(selectedInstancePod).value!,
                        collection: collection.name,
                        filter: collection.uiFilter == null
                            ? null
                            : QueryBuilderUI.parseQuery(collection.uiFilter!),
                        property: property,
                      );

                      return ref
                          .read(isarConnectPod.notifier)
                          .aggregate(query, op);
                    },
                  ),
                  Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10, right: 10),
                      child: Tooltip(
                        message: 'Delete object',
                        child: IconButton(
                          icon: const Icon(Icons.delete),
                          splashRadius: 25,
                          onPressed: () {
                            final collection =
                                ref.read(selectedCollectionPod).valueOrNull;
                            if (collection == null) {
                              return;
                            }

                            final query = ConnectQuery(
                              instance: ref.read(selectedInstancePod).value!,
                              collection: collection.name,
                              filter: FilterCondition.equalTo(
                                property: collection.idName,
                                value: objects[index].getValue(
                                  collection.idName,
                                ),
                              ),
                            );
                            ref
                                .read(isarConnectPod.notifier)
                                .removeQuery(query);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
            separatorBuilder: (BuildContext context, int index) {
              return const SizedBox(height: 15);
            },
          ),
        ),
        const SizedBox(height: 20),
        const PrevNext(),
      ],
    );
  }
}

class TableBlock extends StatefulWidget {
  const TableBlock({
    required super.key,
    required this.collection,
    required this.object,
    required this.editor,
    required this.aggregate,
  });

  final ICollection collection;
  final QueryObject object;
  final Editor editor;
  final Aggregate aggregate;

  @override
  State<TableBlock> createState() => _TableBlockState();
}

class _TableBlockState extends State<TableBlock> {
  late final int _id = widget.object.getValue(widget.collection.idName) as int;
  TreeViewController _treeViewController = TreeViewController();

  @override
  Widget build(BuildContext context) {
    _updateNodes();
    return IsarCard(
      color: const Color(0xFF1F2128),
      padding: const EdgeInsets.fromLTRB(25, 15, 15, 15),
      radius: BorderRadius.circular(5),
      child: TreeView(
        theme: const TreeViewTheme(
          expanderTheme: ExpanderThemeData(color: Colors.white),
        ),
        controller: _treeViewController,
        shrinkWrap: true,
        nodeBuilder: (context, node) {
          return TableItem(
            data: node.data as TreeViewHelper,
            editor: widget.editor,
            objectId: _id,
            aggregate: widget.aggregate,
            treeViewController: _treeViewController,
          );
        },
        onExpansionChanged: (key, expanded) {
          _expanding(_treeViewController.getNode(key)!, expanded);
        },
        onNodeTap: (key) {
          final node = _treeViewController.getNode<TreeViewHelper>(key)!;
          _expanding(node, !node.expanded);
        },
      ),
    );
  }

  void _expanding(Node<TreeViewHelper> node, bool expanded) {
    setState(() {
      _treeViewController = _treeViewController.copyWith(
        children: _treeViewController.updateNode(
          node.key,
          node.copyWith(
            expanded: expanded,
            children: !expanded
                ? _treeViewController.collapseAll(parent: node)
                : null,
          ),
        ),
      );
    });
  }

  void _updateNodes() {
    final children = <Node<TreeViewHelper>>[];

    children.addAll(
      _createProperties(
        properties: widget.collection.allProperties,
        data: widget.object.data,
      ),
    );

    children.addAll(_createLinks());

    _treeViewController = _treeViewController.copyWith(children: children);
  }

  List<Node<TreeViewHelper>> _createProperties({
    required List<IProperty> properties,
    required Map<String, dynamic> data,
    String prefixPath = '',
    String? realPrefixPath,
    String linkKey = '',
    List<IObject>? embeddedObjects,
  }) {
    embeddedObjects = embeddedObjects ?? widget.collection.objects;
    prefixPath = prefixPath.isNotEmpty ? '$prefixPath.' : '';
    realPrefixPath = realPrefixPath == null
        ? prefixPath
        : (realPrefixPath.isNotEmpty ? '$realPrefixPath.' : '');

    return properties.map((property) {
      final path = '$realPrefixPath${property.name}';
      final key = '$prefixPath${property.name}';
      final children = <Node<TreeViewHelper>>[];
      final value = data[property.name];

      if (property.type == IsarType.object) {
        return Node<TreeViewHelper>(
          key: key,
          label: '',
          expanded: _isExpanded(key),
          children: _createProperties(
            properties: embeddedObjects!
                .firstWhere((e) => e.name == property.target)
                .properties,
            data: value as Map<String, dynamic>,
            linkKey: linkKey,
            embeddedObjects: embeddedObjects,
            prefixPath: path,
          ),
          data: PropertyHelper(
            property: property,
            value: value,
            linkKey: linkKey,
            path: path,
          ),
        );
      }

      if (property.type == IsarType.objectList) {
        final list = value as List<dynamic>;

        return Node<TreeViewHelper>(
          key: key,
          label: '',
          expanded: _isExpanded(key),
          children: [
            for (var index = 0; index < list.length; ++index)
              Node<TreeViewHelper>(
                key: '$key.$index',
                label: '',
                expanded: _isExpanded('$key.$index'),
                children: _createProperties(
                  properties: embeddedObjects!
                      .firstWhere((e) => e.name == property.target)
                      .properties,
                  data: list[index] as Map<String, dynamic>,
                  linkKey: linkKey,
                  embeddedObjects: embeddedObjects,
                  prefixPath: '$path.$index',
                ),
                data: PropertyHelper(
                  property: IProperty(
                    name: property.name,
                    type: property.type.scalarType,
                    target: property.target,
                  ),
                  value: list[index],
                  linkKey: linkKey,
                  index: index,
                  path: '$path.$index',
                ),
              )
          ],
          data: PropertyHelper(
            property: property,
            value: list,
            linkKey: linkKey,
            path: path,
          ),
        );
      }

      if (property.type.isList && value != null) {
        final list = value as List<dynamic>;

        for (var index = 0; index < list.length; index++) {
          children.add(
            Node(
              key: '$key.$index',
              label: '',
              expanded: _isExpanded('$key.$index'),
              data: PropertyHelper(
                property: IProperty(
                  name: property.name,
                  type: property.type.scalarType,
                ),
                value: list[index],
                index: index,
                linkKey: linkKey,
                path: '$path.$index',
              ),
            ),
          );
        }
      }

      return Node<TreeViewHelper>(
        key: key,
        label: '',
        expanded: _isExpanded(key),
        children: children,
        data: PropertyHelper(
          property: property,
          value: value,
          linkKey: linkKey,
          path: path,
        ),
      );
    }).toList();
  }

  List<Node<TreeViewHelper>> _createLinks() {
    return widget.collection.links.map((link) {
      final children = <Node<TreeViewHelper>>[];
      final value = widget.object.getValue(link.name);

      if (link.single) {
        if (value != null) {
          children.addAll(
            _createProperties(
              properties: link.target.allProperties,
              data: value as Map<String, dynamic>,
              prefixPath: link.name,
              realPrefixPath: '',
              linkKey: link.name,
              embeddedObjects: link.target.objects,
            ),
          );
        }
      } else {
        final list = value as List<dynamic>;

        for (var index = 0; index < list.length; index++) {
          children.add(
            Node<TreeViewHelper>(
              key: '${link.name}.$index',
              label: '',
              expanded: _isExpanded('${link.name}.$index'),
              children: _createProperties(
                properties: link.target.allProperties,
                data: list[index] as Map<String, dynamic>,
                prefixPath: '${link.name}.$index',
                realPrefixPath: '',
                linkKey: '${link.name}.$index',
                embeddedObjects: link.target.objects,
              ),
              data: LinkHelper(
                link: link,
                value: list[index],
                index: index,
              ),
            ),
          );
        }
      }

      return Node<TreeViewHelper>(
        key: link.name,
        label: '',
        expanded: _isExpanded(link.name),
        children: children,
        data: LinkHelper(
          link: link,
          value: value,
        ),
      );
    }).toList();
  }

  bool _isExpanded(String key) {
    return _treeViewController.getNode<TreeViewHelper>(key)?.expanded ?? false;
  }
}

class TableItem extends StatefulWidget {
  const TableItem({
    super.key,
    required this.data,
    required this.editor,
    required this.objectId,
    required this.aggregate,
    required this.treeViewController,
  });

  final TreeViewHelper data;
  final int objectId;
  final Editor editor;
  final Aggregate aggregate;
  final TreeViewController treeViewController;

  @override
  State<TableItem> createState() => _TableItemState();
}

class _TableItemState extends State<TableItem> {
  bool _entered = false;

  List<PopupMenuEntry<dynamic>> get _options => [
        if (widget.data is LinkHelper && widget.data.value != null)
          PopupMenuItem<dynamic>(
            onTap: () => _copy(true),
            child: const PopUpMenuRow(
              icon: Icon(Icons.copy, size: PopUpMenuRow.iconSize),
              text: 'Copy Id',
            ),
          ),
        PopupMenuItem<dynamic>(
          onTap: _copy,
          child: const PopUpMenuRow(
            icon: Icon(Icons.copy, size: PopUpMenuRow.iconSize),
            text: 'Copy to clipboard',
          ),
        ),
        if (widget.data is PropertyHelper &&
            !(widget.data as PropertyHelper).property.isId &&
            !(widget.data as PropertyHelper).property.type.isList &&
            (widget.data as PropertyHelper).property.type != IsarType.object)
          PopupMenuItem<dynamic>(
            onTap: () {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _edit(),
              );
            },
            child: PopUpMenuRow(
              icon: const Icon(
                Icons.edit,
                size: PopUpMenuRow.iconSize,
              ),
              text: widget.data.index != null
                  ? 'Edit item ${widget.data.index!}'
                  : 'Edit property',
            ),
          ),
        if (widget.data is PropertyHelper && widget.data.index != null)
          PopupMenuItem<dynamic>(
            onTap: _removeListItem,
            child: PopUpMenuRow(
              icon: const Icon(
                Icons.delete,
                size: PopUpMenuRow.iconSize,
              ),
              text: 'Remove item ${widget.data.index!}',
            ),
          ),
        if (widget.data is PropertyHelper &&
            (widget.data as PropertyHelper).property.type.isList &&
            widget.data.value != null &&
            (widget.data as PropertyHelper).property.type !=
                IsarType.objectList)
          PopupMenuItem<dynamic>(
            onTap: () {
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _addInList(null));
            },
            child: const PopUpMenuRow(
              icon: Icon(Icons.add, size: PopUpMenuRow.iconSize),
              text: 'Add item',
            ),
          ),
        if (widget.data is PropertyHelper &&
            widget.data.index != null &&
            (widget.data as PropertyHelper).property.type !=
                IsarType.object) ...[
          PopupMenuItem<dynamic>(
            onTap: () {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _addInList(widget.data.index),
              );
            },
            child: PopUpMenuRow(
              icon: const Icon(
                Icons.add,
                size: PopUpMenuRow.iconSize,
              ),
              text: 'Add item before ${widget.data.index}',
            ),
          ),
          PopupMenuItem<dynamic>(
            onTap: () {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _addInList(widget.data.index! + 1),
              );
            },
            child: PopUpMenuRow(
              icon: const Icon(
                Icons.add,
                size: PopUpMenuRow.iconSize,
              ),
              text: 'Add item after ${widget.data.index}',
            ),
          ),
        ],
        if (widget.data is PropertyHelper &&
            (widget.data as PropertyHelper).property.type.isList)
          PopupMenuItem<dynamic>(
            onTap: () => _setValue(<dynamic>[]),
            child: const PopUpMenuRow(
              text: 'Empty list',
            ),
          ),
        if (widget.data is PropertyHelper &&
            !(widget.data as PropertyHelper).property.isId &&
            widget.data.value != null)
          PopupMenuItem<dynamic>(
            onTap: () => _setValue(null),
            child: const PopUpMenuRow(
              text: 'Set value to null',
            ),
          ),
        // todo: TBA we need to filter object's properties.
        /*
        if ( widget.data is PropertyHelper &&
            (widget.data as PropertyHelper).linkKey.isEmpty &&
            (widget.data as PropertyHelper).index == null &&
            (widget.data as PropertyHelper).property.type.isNum)
          PopupMenuItem(
            padding: EdgeInsets.zero,
            child: PopupMenuButton(
              position: PopupMenuPosition.under,
              tooltip: '',
              onCanceled: () {
                if (Navigator.canPop(context)) {
                  Navigator.pop(context);
                }
              },
              itemBuilder: (BuildContext context) => [
                PopupMenuItem<dynamic>(
                  onTap: () => _aggregate(AggregationOp.min),
                  child: const PopUpMenuRow(text: 'Min'),
                ),
                PopupMenuItem<dynamic>(
                  onTap: () => _aggregate(AggregationOp.max),
                  child: const PopUpMenuRow(text: 'Max'),
                ),
                PopupMenuItem<dynamic>(
                  onTap: () => _aggregate(AggregationOp.sum),
                  child: const PopUpMenuRow(text: 'Sum'),
                ),
                PopupMenuItem<dynamic>(
                  onTap: () => _aggregate(AggregationOp.average),
                  child: const PopUpMenuRow(text: 'Average'),
                ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    PopUpMenuRow(text: 'Aggregation'),
                    Icon(Icons.arrow_right),
                  ],
                ),
              ),
            ),
          ),
          */
      ];

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _entered = true),
      onExit: (_) => setState(() => _entered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              child: widget.data.value is String
                  ? Tooltip(
                      message: widget.data.value.toString(),
                      child: _createText(),
                    )
                  : _createText(),
            ),
            if (_entered)
              PopupMenuButton<dynamic>(
                elevation: 20,
                itemBuilder: (context) => _options,
                tooltip: 'Options',
                child: const Icon(Icons.more_vert, size: 18),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy([bool linkId = false]) async {
    ScaffoldMessenger.of(context).removeCurrentSnackBar();

    if (!linkId) {
      await Clipboard.setData(
        ClipboardData(text: widget.data.value.toString()),
      );
    } else {
      final helper = widget.data as LinkHelper;
      dynamic text;

      if (helper.index != null) {
        text = (helper.value as Map)[helper.link.target.idName];
      } else {
        text = (helper.value as List)
            //ignore: avoid_dynamic_calls
            .map((e) => e[helper.link.target.idName].toString())
            .toList();
      }

      await Clipboard.setData(
        ClipboardData(text: text.toString()),
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 1),
          width: 200,
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Copied To Clipboard',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }
  }

  Future<void> _edit() async {
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          content: EditPopup(
            type: (widget.data as PropertyHelper).property.type,
            value: widget.data.value,
          ),
        );
      },
    );

    if (result != null) {
      await _setValue(result['value']);
    }
  }

  Future<void> _addInList(int? index) async {
    final helper = widget.data as PropertyHelper;
    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          content: EditPopup(
            type: helper.property.type.isList
                ? helper.property.type.scalarType
                : helper.property.type,
            value: null,
          ),
        );
      },
    );

    if (result != null) {
      final objectInfo = _objectInfo(helper);
      if (objectInfo == null) {
        return;
      }

      widget.editor(
        ConnectEdit(
          instance: '',
          collection: objectInfo['collectionName'] as String,
          id: objectInfo['objectId'] as int,
          path: index == null ? helper.path : _parentPath(),
          listIndex: index,
          value: result['value'],
        ),
        EditorType.add,
      );
    }
  }

  Future<void> _setValue(dynamic value) async {
    final helper = widget.data as PropertyHelper;
    final objectInfo = _objectInfo(helper);
    if (objectInfo == null) {
      return;
    }

    widget.editor(
      ConnectEdit(
        instance: '',
        collection: objectInfo['collectionName'] as String,
        id: objectInfo['objectId'] as int,
        path: helper.path,
        listIndex: widget.data.index,
        value: value,
      ),
      EditorType.edit,
    );
  }

  Future<void> _removeListItem() async {
    final objectInfo = _objectInfo();
    if (objectInfo == null) {
      return;
    }

    widget.editor(
      ConnectEdit(
        instance: '',
        collection: objectInfo['collectionName'] as String,
        id: objectInfo['objectId'] as int,
        path: _parentPath(),
        listIndex: widget.data.index,
        value: null,
      ),
      EditorType.remove,
    );
  }

  // todo: query aggregation.
  /*
  Future<void> _aggregate(AggregationOp op) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final property = (widget.data as PropertyHelper).property;
    dynamic result;

    if (property.type == IsarType.int ||
        property.type == IsarType.long ||
        property.type == IsarType.byte) {
      result = (await widget.aggregate(property.name, op))?.toInt();
    } else {
      result = await widget.aggregate(property.name, op);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          width: 300,
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${op.name}(${property.name}) = $result',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }
  }
  */

  Map<String, dynamic>? _objectInfo([PropertyHelper? helper]) {
    helper = helper ?? widget.data as PropertyHelper;

    if (helper.linkKey.isNotEmpty) {
      final linkHelper = widget.treeViewController
          .getNode<TreeViewHelper>(helper.linkKey)
          ?.data as LinkHelper?;
      if (linkHelper == null) {
        return null;
      }
      return {
        'collectionName': linkHelper.link.target.name,
        'objectId':
            (linkHelper.value as Map)[linkHelper.link.target.idName] as int,
      };
    }

    return {'collectionName': '', 'objectId': widget.objectId};
  }

  String _parentPath() {
    final parsedPath = (widget.data as PropertyHelper).path.split('.');
    return parsedPath.take(parsedPath.length - 1).join('.');
  }

  Widget _createText() {
    var value = '';
    var property = '';
    var color = Colors.white;

    if (widget.data is LinkHelper) {
      final helper = widget.data as LinkHelper;

      if (helper.link.single) {
        value = 'Link<${helper.link.target.name}> ';
        if (helper.value == null) {
          value += 'null';
        } else {
          value += '(${(helper.value as Map)[helper.link.target.idName]})';
        }

        property = helper.link.name;
      } else {
        if (helper.index == null) {
          property = helper.link.name;
          value = 'Links<${helper.link.target.name}>'
              ' [${(helper.value as List).length}]';
        } else {
          property = helper.index.toString();
          value = '${helper.link.target.name}'
              //ignore: avoid_dynamic_calls
              ' (${helper.value[helper.link.target.idName]})';
        }
      }
      color = _disableColor;
    } else {
      final prop = (widget.data as PropertyHelper).property;
      if (widget.data.value == null && !prop.type.isList) {
        value = 'null';
        color = _boolColor;
      } else {
        switch (prop.type) {
          case IsarType.bool:
            value = widget.data.value.toString();
            color = _boolColor;
            break;

          case IsarType.dateTime:
            value =
                DateTime.fromMicrosecondsSinceEpoch(widget.data.value as int)
                    .toIso8601String();
            color = _dateColor;
            break;

          case IsarType.object:
            value = prop.target!;
            color = _disableColor;
            break;

          case IsarType.byte:
          case IsarType.int:
          case IsarType.float:
          case IsarType.long:
          case IsarType.double:
            value = widget.data.value.toString();
            color = _numberColor;
            break;

          case IsarType.string:
            value = '"${widget.data.value.toString().replaceAll('\n', '⤵')}"';
            color = _stringColor;
            break;

          case IsarType.byteList:
          case IsarType.intList:
          case IsarType.floatList:
          case IsarType.longList:
          case IsarType.doubleList:
          case IsarType.stringList:
          case IsarType.boolList:
          case IsarType.dateTimeList:
          case IsarType.objectList:
            if (prop.type == IsarType.objectList) {
              value = 'List<${prop.target}> ';
            } else {
              value = 'List<${prop.type.scalarType.name[0].toUpperCase()}'
                  '${prop.type.scalarType.name.substring(1)}> ';
            }
            value += widget.data.value == null
                ? '[null]'
                : '[${(widget.data.value as List).length}]';
            color = _disableColor;
            break;
        }
      }

      property = widget.data.index?.toString() ?? prop.name;
    }

    return RichText(
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        text: '',
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        children: [
          TextSpan(
            text: property,
            style: TextStyle(
              decoration: widget.data is PropertyHelper &&
                      (widget.data as PropertyHelper).property.isIndex
                  ? TextDecoration.underline
                  : null,
              decorationThickness: 2,
              decorationColor: Colors.green,
              decorationStyle: TextDecorationStyle.wavy,
            ),
          ),
          const TextSpan(text: ': '),
          TextSpan(
            text: value,
            style: TextStyle(color: color),
          ),
          if (widget.data is PropertyHelper &&
              (widget.data as PropertyHelper).property.isId)
            const TextSpan(
              text: ' IsarId',
              style: TextStyle(color: _disableColor),
            ),
        ],
      ),
    );
  }
}

class PopUpMenuRow extends StatelessWidget {
  const PopUpMenuRow({super.key, this.icon, required this.text});

  final Icon? icon;
  final String text;

  static const double iconSize = 18;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) icon! else const SizedBox(width: iconSize),
        const SizedBox(width: 15),
        Text(text, style: const TextStyle(fontSize: 15)),
      ],
    );
  }
}

abstract class TreeViewHelper {
  const TreeViewHelper({
    required this.value,
    this.index,
  });

  final dynamic value;
  final int? index;
}

class PropertyHelper extends TreeViewHelper {
  const PropertyHelper({
    required super.value,
    super.index,
    required this.property,
    required this.linkKey,
    required this.path,
  });

  final IProperty property;
  final String linkKey;
  final String path;
}

class LinkHelper extends TreeViewHelper {
  const LinkHelper({
    required super.value,
    super.index,
    required this.link,
  });

  final ILink link;
}
