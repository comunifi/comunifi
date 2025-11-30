import 'dart:typed_data';
import '../crypto/crypto.dart' as mls_crypto;

/// Tree index for any node (leaf or internal)
class NodeIndex {
  final int value;
  const NodeIndex(this.value);
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeIndex && runtimeType == other.runtimeType && value == other.value;
  
  @override
  int get hashCode => value.hashCode;
}

/// Leaf index (references a leaf node in the tree)
class LeafIndex {
  final int value;
  const LeafIndex(this.value);
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LeafIndex && runtimeType == other.runtimeType && value == other.value;
  
  @override
  int get hashCode => value.hashCode;
}

/// Ratchet tree node (can be blank or contain keys/secrets)
class RatchetNode {
  final bool isBlank;
  final mls_crypto.PublicKey? publicKey;
  final mls_crypto.PrivateKey? privateKey;
  final Uint8List? secret;

  RatchetNode.blank()
      : isBlank = true,
        publicKey = null,
        privateKey = null,
        secret = null;

  RatchetNode.withKeys(this.publicKey, this.privateKey, this.secret)
      : isBlank = false;

  RatchetNode copyWith({
    bool? isBlank,
    mls_crypto.PublicKey? publicKey,
    mls_crypto.PrivateKey? privateKey,
    Uint8List? secret,
  }) {
    if (isBlank == true) {
      return RatchetNode.blank();
    }
    return RatchetNode.withKeys(
      publicKey ?? this.publicKey,
      privateKey ?? this.privateKey,
      secret ?? this.secret,
    );
  }
}

// Re-export for convenience
typedef PublicKey = mls_crypto.PublicKey;
typedef PrivateKey = mls_crypto.PrivateKey;

/// Ratchet tree for TreeKEM
class RatchetTree {
  final List<RatchetNode> nodes;

  RatchetTree(this.nodes);

  /// Get the number of leaves in the tree
  int get leafCount {
    if (nodes.isEmpty) return 0;
    if (nodes.length == 1) return 1; // Single node is both root and leaf
    
    // For a complete binary tree: leaves = (nodes.length + 1) ~/ 2
    return (nodes.length + 1) ~/ 2;
  }

  /// Convert leaf index to node index
  int _leafIndexToNodeIndex(int leafIndex) {
    if (nodes.isEmpty) return 0;
    
    final treeSize = nodes.length;
    
    // Special case: single node tree
    if (treeSize == 1) {
      return leafIndex == 0 ? 0 : throw ArgumentError('Invalid leaf index');
    }
    
    // For a complete binary tree with n nodes:
    // First leaf is at index (n-1)~/2
    // Leaves are at indices: firstLeaf, firstLeaf+1, ..., n-1
    final firstLeafIndex = (treeSize - 1) ~/ 2;
    return firstLeafIndex + leafIndex;
  }

  /// Get parent node index
  NodeIndex? parent(NodeIndex node) {
    if (node.value == 0) return null; // Root has no parent
    
    // Parent of node i is at (i - 1) ~/ 2
    final parentIndex = (node.value - 1) ~/ 2;
    if (parentIndex < 0 || parentIndex >= nodes.length) return null;
    
    return NodeIndex(parentIndex);
  }

  /// Get left child node index
  int? _leftChild(int nodeIndex) {
    final childIndex = nodeIndex * 2 + 1;
    if (childIndex >= nodes.length) return null;
    return childIndex;
  }

  /// Get right child node index
  int? _rightChild(int nodeIndex) {
    final childIndex = nodeIndex * 2 + 2;
    if (childIndex >= nodes.length) return null;
    return childIndex;
  }

  /// Get direct path from leaf to root (excluding the leaf itself)
  List<NodeIndex> directPath(LeafIndex leaf) {
    final path = <NodeIndex>[];
    var currentNode = _leafIndexToNodeIndex(leaf.value);
    
    // If single node tree, leaf is root, so no path
    if (nodes.length == 1) {
      return path;
    }
    
    while (currentNode > 0) {
      final parentNode = parent(NodeIndex(currentNode));
      if (parentNode != null) {
        path.add(parentNode);
        currentNode = parentNode.value;
      } else {
        break;
      }
    }
    
    return path.reversed.toList();
  }

  /// Get copath (siblings along the direct path)
  List<NodeIndex> copath(LeafIndex leaf) {
    final copathNodes = <NodeIndex>[];
    var currentNode = _leafIndexToNodeIndex(leaf.value);
    
    // If single node tree, no copath
    if (nodes.length == 1) {
      return copathNodes;
    }
    
    while (currentNode > 0) {
      final parentNode = parent(NodeIndex(currentNode));
      if (parentNode == null) break;
      
      final leftChild = _leftChild(parentNode.value);
      final rightChild = _rightChild(parentNode.value);
      
      if (leftChild != null && rightChild != null) {
        // Add sibling
        if (currentNode == leftChild) {
          copathNodes.add(NodeIndex(rightChild));
        } else if (currentNode == rightChild) {
          copathNodes.add(NodeIndex(leftChild));
        }
      }
      
      currentNode = parentNode.value;
    }
    
    return copathNodes;
  }

  /// Append a new leaf to the tree
  LeafIndex appendLeaf(RatchetNode leaf) {
    final currentLeafCount = leafCount;
    final newLeafIndex = currentLeafCount;
    
    // Calculate required nodes for the new leaf count
    final requiredNodes = _calculateRequiredNodes(newLeafIndex + 1);
    
    // Expand tree if necessary
    while (nodes.length < requiredNodes) {
      nodes.add(RatchetNode.blank());
    }
    
    // Insert leaf at the appropriate position
    final nodeIndex = _leafIndexToNodeIndex(newLeafIndex);
    if (nodeIndex < nodes.length) {
      nodes[nodeIndex] = leaf;
    } else {
      // Expand and insert
      while (nodes.length <= nodeIndex) {
        nodes.add(RatchetNode.blank());
      }
      nodes[nodeIndex] = leaf;
    }
    
    return LeafIndex(newLeafIndex);
  }

  /// Calculate required number of nodes for a given number of leaves
  int _calculateRequiredNodes(int leafCount) {
    if (leafCount == 0) return 0;
    if (leafCount == 1) return 1;
    
    // For a complete binary tree: 2 * leafCount - 1
    return 2 * leafCount - 1;
  }

  /// Blank a subtree starting from a leaf
  void blankSubtree(LeafIndex leaf) {
    final nodeIndex = _leafIndexToNodeIndex(leaf.value);
    if (nodeIndex >= nodes.length) return;
    
    // Blank the leaf
    nodes[nodeIndex] = RatchetNode.blank();
    
    // Blank ancestors up to root
    var current = nodeIndex;
    while (current > 0) {
      final parentNode = parent(NodeIndex(current));
      if (parentNode != null) {
        nodes[parentNode.value] = RatchetNode.blank();
        current = parentNode.value;
      } else {
        break;
      }
    }
  }
}

