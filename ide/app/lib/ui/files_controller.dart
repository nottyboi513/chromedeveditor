// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * This class implements the controller for the list of files.
 */
library spark.ui.widgets.files_controller;

import 'dart:async';
import 'dart:convert' show JSON;
import 'dart:html' as html;

import 'package:bootjack/bootjack.dart' as bootjack;

import 'utils/html_utils.dart';
import 'widgets/file_item_cell.dart';
import 'widgets/listview_cell.dart';
import 'widgets/treeview.dart';
import 'widgets/treeview_cell.dart';
import 'widgets/treeview_delegate.dart';
import '../actions.dart';
import '../event_bus.dart';
import '../preferences.dart' as preferences;
import '../scm.dart';
import '../workspace.dart';

class FilesControllerSelectionChangedEvent extends BusEvent {
  Resource resource;
  bool forceOpen;
  bool replaceCurrent;
  bool switchesTab;

  FilesControllerSelectionChangedEvent(
      this.resource,
      {this.forceOpen: false,
       this.replaceCurrent: true,
       this.switchesTab: true});

  BusEventType get type => BusEventType.FILES_CONTROLLER__SELECTION_CHANGED;
}

class FilesController implements TreeViewDelegate {
  // TreeView that's used to show the workspace.
  TreeView _treeView;
  // Workspace that references all the resources.
  final Workspace _workspace;
  // Used to get a list of actions in the context menu for a resource.
  final ActionManager _actionManager;
  // The SCMManager is used to help us decorate files with their SCM status.
  final ScmManager _scmManager;
  // List of top-level resources.
  final List<Resource> _files = [];
  // Map of nodeUuid to the resources of the workspace for a quick lookup.
  final Map<String, Resource> _filesMap = {};
  // Cache of sorted children of nodes.
  final Map<String, List<String>> _childrenCache = {};
  // Preferences where to store tree expanded/collapsed state.
  final preferences.PreferenceStore localPrefs = preferences.localStore;
  // The event bus to post events for file selection in the tree.
  final EventBus _eventBus;
  // HTML container for the context menu.
  html.Element _menuContainer;
  // Filter the list of files by filename containing this string.
  String _filterString;
  // List of filtered top-level resources.
  List<Resource> _filteredFiles;
  // Sorted children of nodes.
  Map<String, List<String>> _filteredChildrenCache;

  FilesController(this._workspace,
                  this._actionManager,
                  this._scmManager,
                  this._eventBus,
                  this._menuContainer,
                  html.Element fileViewArea) {
    _treeView = new TreeView(fileViewArea, this);
    _treeView.dropEnabled = true;
    _treeView.draggingEnabled = true;

    _workspace.whenAvailable().then((_) => _addAllFiles());

    _workspace.onResourceChange.listen((event) {
      bool hasAddsDeletes = event.changes.any((d) => d.isAdd || d.isDelete);
      if (hasAddsDeletes) _processEvents(event);
    });

    _workspace.onMarkerChange.listen((_) => _processMarkerChange());
    _scmManager.onStatusChange.listen((_) => _processScmChange());
  }

  bool isFileSelected(Resource file) {
    return _treeView.selection.contains(file.uuid);
  }

  List<Resource> _currentFiles() {
    return _filteredFiles != null ?  _filteredFiles : _files;
  }

   Map<String, List<String>> _currentChildrenCache() {
    return  _filteredChildrenCache != null ? _filteredChildrenCache : _childrenCache;
  }

  void selectFile(Resource file, {bool forceOpen: false}) {
    if (_currentFiles().isEmpty) {
      return;
    }

    List parents = _collectParents(file, []);

    parents.forEach((Container container) {
      if (!_treeView.isNodeExpanded(container.uuid)) {
        _treeView.setNodeExpanded(container.uuid, true);
      }
    });

    _treeView.selection = [file.uuid];
    _treeView.scrollIntoNode(file.uuid, html.ScrollAlignment.CENTER);
    _eventBus.addEvent(
        new FilesControllerSelectionChangedEvent(
            file, forceOpen: forceOpen));
  }

  void selectFirstFile({bool forceOpen: false}) {
    if (_currentFiles().isEmpty) {
      return;
    }
    selectFile(_currentFiles()[0], forceOpen: forceOpen);
  }

  void setFolderExpanded(Container resource) {
    for (Container container in _collectParents(resource, [])) {
      if (!_treeView.isNodeExpanded(container.uuid)) {
        _treeView.setNodeExpanded(container.uuid, true);
      }
    }

    _treeView.setNodeExpanded(resource.uuid, true);
  }

  // Implementation of [TreeViewDelegate] interface.

  bool treeViewHasChildren(TreeView view, String nodeUuid) {
    if (nodeUuid == null) {
      return true;
    } else {
      return (_filesMap[nodeUuid] is Container);
    }
  }

  int treeViewNumberOfChildren(TreeView view, String nodeUuid) {
    if (nodeUuid == null) {
      return _currentFiles().length;
    } else if (_filesMap[nodeUuid] is Container) {
      _cacheChildren(nodeUuid);
      if (_currentChildrenCache()[nodeUuid] == null) {
        return 0;
      }
      return _currentChildrenCache()[nodeUuid].length;
    } else {
      return 0;
    }
  }

  String treeViewChild(TreeView view, String nodeUuid, int childIndex) {
    if (nodeUuid == null) {
      return _currentFiles()[childIndex].uuid;
    } else {
      _cacheChildren(nodeUuid);
      return _currentChildrenCache()[nodeUuid][childIndex];
    }
  }

  List<Resource> getSelection() {
    List resources = [];
    _treeView.selection.forEach((String nodeUuid) {
      resources.add(_filesMap[nodeUuid]);
    });
    return resources;
  }

  ListViewCell treeViewCellForNode(TreeView view, String nodeUuid) {
    Resource resource = _filesMap[nodeUuid];
    assert(resource != null);
    FileItemCell cell = new FileItemCell(resource);
    if (resource is Folder) {
      cell.acceptDrop = true;
    }
    _updateScmInfo(cell);
    return cell;
  }

  int treeViewHeightForNode(TreeView view, String nodeUuid) => 20;

  void treeViewSelectedChanged(TreeView view,
                               List<String> nodeUuids) {
    if (nodeUuids.isNotEmpty) {
      Resource resource = _filesMap[nodeUuids.first];
      _eventBus.addEvent(
          new FilesControllerSelectionChangedEvent(
              resource, forceOpen: true, replaceCurrent: true));
    }
  }

  bool treeViewRowClicked(html.MouseEvent event, String uid) {
    if (uid == null) {
      return true;
    }

    Resource resource = _filesMap[uid];
    if (resource is File) {
      bool altKeyPressed = event.altKey;
      bool shiftKeyPressed = event.shiftKey;
      bool ctrlKeyPressed = event.ctrlKey;

      // Open in editor only if alt key or no modifier key is down.  If alt key
      // is pressed, it will open a new tab.
      if (altKeyPressed && !shiftKeyPressed && !ctrlKeyPressed) {
        _eventBus.addEvent(
            new FilesControllerSelectionChangedEvent(
                resource, forceOpen: true, replaceCurrent: false));
        return false;
      }
    }

    return true;
  }

  void treeViewDoubleClicked(TreeView view,
                             List<String> nodeUuids,
                             html.Event event) {
    if (nodeUuids.length == 1 && _filesMap[nodeUuids.first] is Container) {
      view.toggleNodeExpanded(nodeUuids.first, animated: true);
    }
  }

  void treeViewContextMenu(TreeView view,
                           List<String> nodeUuids,
                           String nodeUuid,
                           html.Event event) {
    cancelEvent(event);
    Resource resource = _filesMap[nodeUuid];
    FileItemCell cell = new FileItemCell(resource);
    _showMenuForEvent(cell, event, resource);
  }

  String treeViewDropEffect(TreeView view,
                            html.DataTransfer dataTransfer,
                            String nodeUuid) {
    if (dataTransfer.types.contains('Files')) {
      if (nodeUuid == null) {
        // Importing to top-level is not allowed for now.
        return "none";
      } else {
        // Import files into a folder.
        return "copy";
      }
    } else {
      // Move files inside top-level folder.
      return "move";
    }
  }

  String treeViewDropCellsEffect(TreeView view,
                                 List<String> nodesUIDs,
                                 String nodeUuid) {
    if (nodeUuid == null) {
      return "none";
    }
    if (_isDifferentProject(nodesUIDs, nodeUuid)) {
      return "copy";
    } else {
      if (_isValidMove(nodesUIDs, nodeUuid)) {
        return "move";
      } else {
        return "none";
      }
    }
  }

  void treeViewDrop(TreeView view, String nodeUuid, html.DataTransfer dataTransfer) {
    Folder destinationFolder = _filesMap[nodeUuid] as Folder;
    for (html.File file in dataTransfer.files) {
      html.FileReader reader = new html.FileReader();
      reader.onLoadEnd.listen((html.ProgressEvent event) {
        destinationFolder.createNewFile(file.name).then((File file) {
          file.setBytes(reader.result);
        });
      });
      reader.readAsArrayBuffer(file);
    }
  }

  bool _isDifferentProject(List<String> nodesUIDs, String targetNodeUID) {
    if (targetNodeUID == null) {
      return false;
    }
    Resource destination = _filesMap[targetNodeUID];
    Project destinationProject = destination is Project ? destination :
        destination.project;
    for (String nodeUuid in nodesUIDs) {
      Resource node = _filesMap[nodeUuid];
      // Check if the resource have the same top-level container.
      if (node.project == destinationProject) {
        return false;
      }
    }
    return true;
  }

  // Returns true if the move is valid:
  // - We don't allow moving a file to its parent since it's a no-op.
  // - We don't allow moving an ancestor folder to one of its descendant.
  bool _isValidMove(List<String> nodesUIDs, String targetNodeUID) {
    if (targetNodeUID == null) {
      return false;
    }
    Resource destination = _filesMap[targetNodeUID];
    // Collect list of ancestors of the destination.
    Set<String> ancestorsUIDs = new Set();
    Resource currentNode = destination;
    while (currentNode != null) {
      ancestorsUIDs.add(currentNode.uuid);
      currentNode = currentNode.parent;
    }
    // Make sure that source items are not one of them.
    for (String nodeUuid in nodesUIDs) {
      if (ancestorsUIDs.contains(nodeUuid)) {
        // Unable to move this file.
        return false;
      }
    }

    Project destinationProject = destination is Project ? destination :
        destination.project;
    for (String nodeUuid in nodesUIDs) {
      Resource node = _filesMap[nodeUuid];
      // Check whether a resource is moved to its current directory, which would
      // make it a no-op.
      if (node.parent == destination) {
        // Unable to move this file.
        return false;
      }
      // Check if the resource have the same top-level container.
      if (node.project != destinationProject) {
        return false;
      }
    }

    return true;
  }

  void treeViewDropCells(TreeView view,
                         List<String> nodesUIDs,
                         String targetNodeUID) {
    Folder destination = _filesMap[targetNodeUID] as Folder;
    if (_isDifferentProject(nodesUIDs, targetNodeUID)) {
      List<Future> futures = [];
      for (String nodeUuid in nodesUIDs) {
        Resource res = _filesMap[nodeUuid];
        futures.add(destination.importResource(res));
      }
      Future.wait(futures).catchError((e) {
        _eventBus.addEvent(
            new ErrorMessageBusEvent('Error while importing files', e));
      });
    } else {
      if (_isValidMove(nodesUIDs, targetNodeUID)) {
        _workspace.moveTo(nodesUIDs.map((f) => _filesMap[f]).toList(), destination);
      }
    }
  }

  bool treeViewAllowsDropCells(TreeView view,
                               List<String> nodesUIDs,
                               String destinationNodeUID) {
    if (_isDifferentProject(nodesUIDs, destinationNodeUID)) {
      return true;
    } else {
      return _isValidMove(nodesUIDs, destinationNodeUID);
    }
  }

  bool treeViewAllowsDrop(TreeView view,
                          html.DataTransfer dataTransfer,
                          String destinationNodeUID) {
    if (destinationNodeUID == null) {
      return false;
    }
    return dataTransfer.types.contains('Files');
  }

  /*
   * Drawing the drag image.
   */

  // Constants to draw the drag image.

  // Font for the filenames in the stack.
  final String stackItemFontName = '15px Helvetica';
  // Font for the counter.
  final String counterFontName = '12px Helvetica';
  // Basic height of an item in the stack.
  final int stackItemHeight = 30;
  // Stack item radius.
  final int stackItemRadius = 15;
  // Additional space for shadow.
  final int additionalShadowSpace = 10;
  // Space between stack and counter.
  final int stackCounterSpace = 5;
  // Stack item interspace.
  final int stackItemInterspace = 3;
  // Text padding in the stack item.
  final int stackItemPadding = 10;
  // Counter padding.
  final int counterPadding = 10;
  // Counter height.
  final int counterHeight = 20;
  // Stack item text vertical position
  final int stackItemTextPosition = 20;
  // Counter text vertical position
  final int counterTextPosition = 15;

  TreeViewDragImage treeViewDragImage(TreeView view,
                                      List<String> nodesUIDs,
                                      html.MouseEvent event) {
    if (nodesUIDs.length == 0) {
      return null;
    }

    // The generated image will show a stack of files. The first file will be
    // on the top of it.
    //
    // placeholderCount is the number of files other than the first file that
    // will be shown in the stack.
    // The number of files will also be shown in a badge if there's more than
    // one file.
    int placeholderCount = nodesUIDs.length - 1;

    // We will shows 4 placeholders maximum.
    if (placeholderCount >= 4) {
      placeholderCount = 4;
    }

    html.CanvasElement canvas = new html.CanvasElement();

    // Measure text size.
    html.CanvasRenderingContext2D context = canvas.getContext("2d");
    Resource resource = _filesMap[nodesUIDs.first];
    int stackLabelWidth = _getTextWidth(context, stackItemFontName, resource.name);
    String counterString = '${nodesUIDs.length}';
    int counterWidth =
        _getTextWidth(context, counterFontName, counterString);

    // Set canvas size.
    int globalHeight = stackItemHeight + placeholderCount *
        stackItemInterspace + additionalShadowSpace;
    canvas.width = stackLabelWidth + stackItemPadding * 2 + placeholderCount *
        stackItemInterspace + stackCounterSpace + counterWidth +
        counterPadding * 2 + additionalShadowSpace;
    canvas.height = globalHeight;

    context = canvas.getContext("2d");

    _drawStack(context, placeholderCount, stackLabelWidth, resource.name);
    if (placeholderCount > 0) {
      int x = stackLabelWidth + stackItemPadding * 2 + stackCounterSpace +
          placeholderCount * 2;
      int y = (globalHeight - additionalShadowSpace - counterHeight) ~/ 2;
      _drawCounter(context, x, y, counterWidth, counterString);
    }

    html.ImageElement img = new html.ImageElement();
    img.src = canvas.toDataUrl();
    return new TreeViewDragImage(img, event.offset.x, event.offset.y);
  }

  /**
   * Returns width of a text in pixels.
   */
  int _getTextWidth(html.CanvasRenderingContext2D context,
                    String fontName,
                    String text) {
    context.font = fontName;
    html.TextMetrics metrics = context.measureText(text);
    return metrics.width.toInt();
  }

  /**
   * Set the rendering shadow on the given context.
   */
  void _setShadow(html.CanvasRenderingContext2D context,
                  int blurSize,
                  String color,
                  int offsetX,
                  int offsetY) {
    context.shadowBlur = blurSize;
    context.shadowColor = color;
    context.shadowOffsetX = offsetX;
    context.shadowOffsetY = offsetY;
  }

  /**
   * Draw the stack.
   * `placeholderCount` is the number of items in the stack.
   * `stackLabelWidth` is the width of the text of the first stack item.
   * `stackLabel` is the string to show for the first stack item.
   */
  void _drawStack(html.CanvasRenderingContext2D context,
                  int placeholderCount,
                  int stackLabelWidth,
                  String stackLabel) {
    // Set shadows.
    _setShadow(context, 5, 'rgba(0, 0, 0, 0.3)', 0, 1);

    // Draws items of the stack.
    context.setFillColorRgb(255, 255, 255, 1);
    context.setStrokeColorRgb(128, 128, 128, 1);
    context.lineWidth = 1;
    for (int i = placeholderCount; i >= 0; i--) {
      html.Rectangle rect = new html.Rectangle(0.5 + i * stackItemInterspace,
          0.5 + i * stackItemInterspace,
          stackLabelWidth + stackItemPadding * 2,
          stackItemHeight);
      roundRect(context,
          rect,
          radius: stackItemRadius,
          fill: true,
          stroke: true);
    }

    // No shadows.
    _setShadow(context, 0, 'rgba(0, 0, 0, 0)', 0, 0);

    // Draw text in the stack item.
    context.font = stackItemFontName;
    context.setFillColorRgb(0, 0, 0, 1);
    context.fillText(stackLabel, stackItemPadding, stackItemTextPosition);
  }

  /**
   * Draw the counter and its bezel.
   *
   */
  void _drawCounter(html.CanvasRenderingContext2D context,
                    int x,
                    int y,
                    int counterWidth,
                    String counterString) {
    // Draw counter bezel.
    context.lineWidth = 3;
    context.setFillColorRgb(128, 128, 255, 1);
    html.Rectangle rect = new html.Rectangle(x,
        y,
        counterWidth + counterPadding * 2,
        counterHeight);
    roundRect(context, rect, radius: 10, fill: true, stroke: false);

    // Draw text of counter.
    context.font = counterFontName;
    context.setFillColorRgb(255, 255, 255, 1);
    context.fillText(counterString,
        x + counterPadding,
        y + counterTextPosition);
  }

  void treeViewSaveExpandedState(TreeView view) {
    localPrefs.setValue('FilesExpandedState',
        JSON.encode(_treeView.expandedState));
  }

  // Cache management for sorted list of resources.

  void _cacheChildren(String nodeUuid) {
    if (_childrenCache[nodeUuid] == null) {
      Container container = _filesMap[nodeUuid];
      List<Resource> children =
          container.getChildren().where(_showResource).toList();
      // Sort folders first, then files.
      children.sort(_compareResources);
      _childrenCache[nodeUuid] = children.map((r) => r.uuid).toList();
    }
  }

  void _clearChildrenCache() {
    _childrenCache.clear();
  }

  void _sortTopLevel() {
    _files.sort(_compareResources);
  }

  int _compareResources(Resource a, Resource b) {
    // Show top-level files before folders.
    if (a is File && b is Container) {
      return 1;
    } else if (a is Container && b is File) {
      return -1;
    } else {
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
  }

  void _reloadData() {
    _clearChildrenCache();
    _treeView.reloadData();
  }

  // Processing workspace events.

  void _addAllFiles() {
    for (Resource resource in _workspace.getChildren()) {
      _files.add(resource);
      _recursiveAddResource(resource);
    }
    _sortTopLevel();
    localPrefs.getValue('FilesExpandedState').then((String state) {
      if (state != null) {
        _treeView.restoreExpandedState(JSON.decode(state));
      } else {
        _treeView.reloadData();
      }
    });
  }

  /**
   * Event handler for workspace events.
   */
  void _processEvents(ResourceChangeEvent event) {
    event.changes.where((d) => _showResource(d.resource)).forEach((change) {
      if (change.type == EventType.ADD) {
        var resource = change.resource;
        if (resource.isTopLevel) {
          _files.add(resource);
        }
        _filesMap[resource.uuid] = resource;
      } else if (change.type == EventType.DELETE) {
        var resource = change.resource;
        if (resource.isTopLevel) {
          _files.remove(resource);
        }
        _filesMap.remove(resource.uuid);
      } else if (change.type == EventType.CHANGE) {
        var resource = change.resource;
        _filesMap[resource.uuid] = resource;
      }
    });

    _sortTopLevel();
    _reloadData();
  }

  /**
   * Returns whether the given resource should be filtered from the Files view.
   */
  bool _showResource(Resource resource) => !resource.isScmPrivate();

  /**
   * Traverse all the created [FileItemCell]s, calling `updateFileStatus()`.
   */
  void _processMarkerChange() {
    for (String uid in _filesMap.keys) {
      TreeViewCell treeViewCell = _treeView.getTreeViewCellForUID(uid);

      if (treeViewCell != null) {
        FileItemCell fileItemCell = treeViewCell.embeddedCell;
        fileItemCell.updateFileStatus();
      }
    }
  }

  void _processScmChange() {
    for (String uid in _filesMap.keys) {
      TreeViewCell treeViewCell = _treeView.getTreeViewCellForUID(uid);
      if (treeViewCell != null) {
        _updateScmInfo(treeViewCell.embeddedCell);
      }
    }
  }

  void _updateScmInfo(FileItemCell fileItemCell) {
    Resource resource = fileItemCell.resource;
    ScmProjectOperations scmOperations =
        _scmManager.getScmOperationsFor(resource.project);

    if (scmOperations != null) {
      if (resource is Project) {
        String branchName = scmOperations.getBranchName();
        final String repoIcon = '<span class="glyphicon glyphicon-random small"></span>';
        if (branchName == null) branchName = '';
        fileItemCell.setFileInfo('${repoIcon} [${branchName}]');
      }

      // TODO(devoncarew): for now, just show git status for files. We need to
      // also implement this for folders.
      if (resource is File) {
        FileStatus status = scmOperations.getFileStatus(resource);
        fileItemCell.setGitStatus(dirty: (status != FileStatus.COMMITTED));
      }
    }
  }

  void _recursiveAddResource(Resource resource) {
    _filesMap[resource.uuid] = resource;
    if (resource is Container) {
      resource.getChildren().forEach((child) {
        if (_showResource(child)) {
          _recursiveAddResource(child);
        }
      });
    }
  }

  /**
   * Shows the context menu at the location of the mouse event.
   */
  void _showMenuForEvent(FileItemCell cell,
                         html.MouseEvent event,
                         Resource resource) {
    _showMenuAtLocation(cell, event.client, resource);
  }

  /**
   * Position the context menu at the expected location.
   */
  void _positionContextMenu(html.Point clickPoint, html.Element contextMenu) {
    var topUi = html.document.querySelector("#topUi");
    final int separatorHeight = 19;
    final int itemHeight = 26;
    int estimatedHeight = 12; // Start with value padding and border.
    contextMenu.children.forEach((child) {
      estimatedHeight += child.className == "divider" ? separatorHeight : itemHeight;
    });

    contextMenu.style.left = '${clickPoint.x}px';
    // If context menu exceed Window area.
    if (estimatedHeight + clickPoint.y > topUi.offsetHeight) {
      var positionY = clickPoint.y - estimatedHeight;
      if (positionY < 0) {
        // Add additional 5px to show boundary of context menu.
        contextMenu.style.top = '${topUi.offsetHeight - estimatedHeight - 5}px';
      } else {
        contextMenu.style.top = '${positionY}px';
      }
    } else {
      contextMenu.style.top = '${clickPoint.y}px';
    }
  }

  /**
   * Shows the context menu at given location.
   */
  void _showMenuAtLocation(FileItemCell cell,
                           html.Point position,
                           Resource resource) {
    if (!_treeView.selection.contains(resource.uuid)) {
      _treeView.selection = [resource.uuid];
    }

    html.Element contextMenu = _menuContainer.querySelector('.dropdown-menu');
    // Delete any existing menu items.
    contextMenu.children.clear();

    List<Resource> resources = getSelection();
    // Get all applicable actions.
    List<ContextAction> actions = _actionManager.getContextActions(resources);
    fillContextMenu(contextMenu, actions, resources);
    _positionContextMenu(position, contextMenu);

    // Show the menu.
    bootjack.Dropdown dropdown = bootjack.Dropdown.wire(contextMenu);
    dropdown.toggle();

    void _closeContextMenu(html.Event event) {
      // We workaround an issue with bootstrap/boojack: There's no other way
      // to close the dropdown. For example dropdown.toggle() won't work.
      _menuContainer.classes.remove('open');
      cancelEvent(event);

      _treeView.focus();
    }

    // When the user clicks outside the menu, we'll close it.
    html.Element backdrop = _menuContainer.querySelector('.backdrop');
    backdrop.onClick.listen((event) {
      _closeContextMenu(event);
    });
    backdrop.onContextMenu.listen((event) {
      _closeContextMenu(event);
    });
    // When the user click on an item in the list, the menu will be closed.
    contextMenu.children.forEach((html.Element element) {
      element.onClick.listen((html.Event event) {
        _closeContextMenu(event);
      });
    });
  }

  List _collectParents(Resource resource, List parents) {
    if (resource.isTopLevel) return parents;

    Container parent = resource.parent;

    if (parent != null) {
      parents.insert(0, parent);
      return _collectParents(parent, parents);
    } else {
      return parents;
    }
  }

  /**
   * Add the given resource to the results.
   * [result] is a set that contains uuid of resources that have already been
   * added.
   * [roots] is the resulting list of top-level resources.
   * [childrenCache] is the resulting map between the resource UUID and the
   * list of children.
   * [res] is the resource to add.
   */
  void _filterAddResult(Set result,
      List<Resource> roots,
      Map<String, List<String>> childrenCache,
      Resource res) {
    if (result.contains(res.uuid)) {
      return;
    }
    if (res.parent == null) {
      return;
    }
    result.add(res.uuid);
    if (res.parent.parent == null) {
      roots.add(res);
      return;
    }
    List<String> children = childrenCache[res.parent.uuid];
    if (children == null) {
      children = [];
      childrenCache[res.parent.uuid] = children;
    }
    children.add(res.uuid);
    _filterAddResult(result, roots, childrenCache, res.parent);
  }

  void performFilter(String filterString) {
    if (filterString != null && filterString.isEmpty) {
      filterString = null;
    }
    _filterString = filterString;
    if (_filterString == null) {
      _filteredFiles = null;
      _filteredChildrenCache = null;
      _reloadData();
    } else {
      Set<String> filtered = new Set();
      _filteredFiles = [];
      _filteredChildrenCache = {};
      _filesMap.forEach((String key, Resource res) {
        if (res.name.contains(_filterString)) {
          _filterAddResult(filtered, _filteredFiles, _filteredChildrenCache, res);
        }
      });
      _filteredChildrenCache.forEach((String key, List<String> value) {
        value.sort((String a, String b) {
          Resource resA = _filesMap[a];
          Resource resB = _filesMap[b];
          return _compareResources(resA, resB);
        });
      });

      _reloadData();
      _treeView.restoreExpandedState(filtered.toList());
    }
  }
}
