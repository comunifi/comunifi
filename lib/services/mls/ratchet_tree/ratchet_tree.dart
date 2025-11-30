import 'dart:typed_data';
import '../crypto/crypto.dart' as mls_crypto;
import '../crypto/default_crypto.dart';

/// Tree index for any node (leaf or internal)
class NodeIndex {
  final int value;
  const NodeIndex(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeIndex &&
          runtimeType == other.runtimeType &&
          value == other.value;

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
      other is LeafIndex &&
          runtimeType == other.runtimeType &&
          value == other.value;

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

  /// Serialize ratchet node to bytes
  Uint8List serialize() {
    // Format: is_blank (1 byte) + public_key_length (4 bytes) + public_key + private_key_length (4 bytes) + private_key + secret_length (4 bytes) + secret
    int totalLength = 1; // is_blank

    final publicKeyBytes = publicKey?.bytes;
    final privateKeyBytes = privateKey?.bytes;
    final secretBytes = secret;

    totalLength += 4 + (publicKeyBytes?.length ?? 0);
    totalLength += 4 + (privateKeyBytes?.length ?? 0);
    totalLength += 4 + (secretBytes?.length ?? 0);

    final result = Uint8List(totalLength);
    int offset = 0;

    // Write is_blank
    result[offset++] = isBlank ? 1 : 0;

    // Write public key
    if (publicKeyBytes != null) {
      final length = publicKeyBytes.length;
      result[offset++] = (length >> 24) & 0xFF;
      result[offset++] = (length >> 16) & 0xFF;
      result[offset++] = (length >> 8) & 0xFF;
      result[offset++] = length & 0xFF;
      result.setRange(offset, offset + length, publicKeyBytes);
      offset += length;
    } else {
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
    }

    // Write private key
    if (privateKeyBytes != null) {
      final length = privateKeyBytes.length;
      result[offset++] = (length >> 24) & 0xFF;
      result[offset++] = (length >> 16) & 0xFF;
      result[offset++] = (length >> 8) & 0xFF;
      result[offset++] = length & 0xFF;
      result.setRange(offset, offset + length, privateKeyBytes);
      offset += length;
    } else {
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
    }

    // Write secret
    if (secretBytes != null) {
      final length = secretBytes.length;
      result[offset++] = (length >> 24) & 0xFF;
      result[offset++] = (length >> 16) & 0xFF;
      result[offset++] = (length >> 8) & 0xFF;
      result[offset++] = length & 0xFF;
      result.setRange(offset, offset + length, secretBytes);
      offset += length;
    } else {
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
      result[offset++] = 0;
    }

    return result;
  }

  /// Deserialize ratchet node from bytes
  /// Returns (node, bytesRead)
  static (RatchetNode, int) deserialize(Uint8List data, int offset) {
    int startOffset = offset;

    // Read is_blank
    final isBlank = data[offset++] == 1;

    if (isBlank) {
      return (RatchetNode.blank(), offset - startOffset);
    }

    // Read public key
    final publicKeyLength =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    mls_crypto.PublicKey? publicKey;
    if (publicKeyLength > 0) {
      final publicKeyBytes = data.sublist(offset, offset + publicKeyLength);
      publicKey = DefaultPublicKey(publicKeyBytes);
      offset += publicKeyLength;
    }

    // Read private key
    final privateKeyLength =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    mls_crypto.PrivateKey? privateKey;
    if (privateKeyLength > 0) {
      final privateKeyBytes = data.sublist(offset, offset + privateKeyLength);
      privateKey = DefaultPrivateKey(privateKeyBytes);
      offset += privateKeyLength;
    }

    // Read secret
    final secretLength =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    Uint8List? secret;
    if (secretLength > 0) {
      secret = data.sublist(offset, offset + secretLength);
      offset += secretLength;
    }

    return (
      RatchetNode.withKeys(publicKey, privateKey, secret),
      offset - startOffset,
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

  /// Serialize ratchet tree to bytes
  Uint8List serialize() {
    // Format: node_count (4 bytes) + [nodes...]
    // Each node: is_blank (1 byte) + public_key_length (4 bytes) + public_key + private_key_length (4 bytes) + private_key + secret_length (4 bytes) + secret
    final nodeCount = nodes.length;
    final nodeData = <Uint8List>[];
    int totalLength = 4; // node_count

    for (final node in nodes) {
      final nodeBytes = node.serialize();
      nodeData.add(nodeBytes);
      totalLength += nodeBytes.length;
    }

    final result = Uint8List(totalLength);
    int offset = 0;

    // Write node count
    result[offset++] = (nodeCount >> 24) & 0xFF;
    result[offset++] = (nodeCount >> 16) & 0xFF;
    result[offset++] = (nodeCount >> 8) & 0xFF;
    result[offset++] = nodeCount & 0xFF;

    // Write nodes
    for (final nodeBytes in nodeData) {
      result.setRange(offset, offset + nodeBytes.length, nodeBytes);
      offset += nodeBytes.length;
    }

    return result;
  }

  /// Deserialize ratchet tree from bytes
  static RatchetTree deserialize(Uint8List data) {
    int offset = 0;

    // Read node count
    final nodeCount =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;

    final nodes = <RatchetNode>[];
    for (int i = 0; i < nodeCount; i++) {
      final (node, bytesRead) = RatchetNode.deserialize(data, offset);
      nodes.add(node);
      offset += bytesRead;
    }

    return RatchetTree(nodes);
  }
}
