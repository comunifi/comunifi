import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('RatchetTree Tests', () {
    test('NodeIndex and LeafIndex creation', () {
      final nodeIndex = NodeIndex(5);
      final leafIndex = LeafIndex(2);

      expect(nodeIndex.value, equals(5));
      expect(leafIndex.value, equals(2));
    });

    test('RatchetNode blank node', () {
      final node = RatchetNode.blank();

      expect(node.isBlank, isTrue);
      expect(node.publicKey, isNull);
      expect(node.privateKey, isNull);
      expect(node.secret, isNull);
    });

    test('RatchetTree parent calculation', () {
      // For a binary tree:
      // Node 0 (root)
      // Node 1 (left child of 0)
      // Node 2 (right child of 0)
      // Node 3 (left child of 1)
      // Node 4 (right child of 1)
      // Node 5 (left child of 2)
      // Node 6 (right child of 2)

      final tree = RatchetTree(List.filled(7, RatchetNode.blank()));

      expect(tree.parent(NodeIndex(1))?.value, equals(0));
      expect(tree.parent(NodeIndex(2))?.value, equals(0));
      expect(tree.parent(NodeIndex(3))?.value, equals(1));
      expect(tree.parent(NodeIndex(4))?.value, equals(1));
      expect(tree.parent(NodeIndex(5))?.value, equals(2));
      expect(tree.parent(NodeIndex(6))?.value, equals(2));
      expect(tree.parent(NodeIndex(0)), isNull); // root has no parent
    });

    test('RatchetTree directPath for single leaf', () {
      final tree = RatchetTree([RatchetNode.blank()]);
      final path = tree.directPath(LeafIndex(0));

      expect(path.length, equals(0)); // Single node, no path to root
    });

    test('RatchetTree directPath for two leaves', () {
      // Tree structure:
      //     0 (root)
      //    / \
      //   1   2 (leaves)
      final tree = RatchetTree([
        RatchetNode.blank(), // 0
        RatchetNode.blank(), // 1
        RatchetNode.blank(), // 2
      ]);

      final path0 = tree.directPath(LeafIndex(0));
      expect(path0, contains(NodeIndex(0)));

      final path1 = tree.directPath(LeafIndex(1));
      expect(path1, contains(NodeIndex(0)));
    });

    test('RatchetTree copath for two leaves', () {
      final tree = RatchetTree([
        RatchetNode.blank(), // 0
        RatchetNode.blank(), // 1
        RatchetNode.blank(), // 2
      ]);

      final copath0 = tree.copath(LeafIndex(0));
      expect(copath0, contains(NodeIndex(2))); // sibling of leaf 1

      final copath1 = tree.copath(LeafIndex(1));
      expect(copath1, contains(NodeIndex(1))); // sibling of leaf 2
    });

    test('RatchetTree appendLeaf increases tree size', () {
      final tree = RatchetTree([RatchetNode.blank()]);
      expect(tree.nodes.length, equals(1));

      final leafIndex1 = tree.appendLeaf(RatchetNode.blank());
      expect(leafIndex1.value, equals(1));
      expect(tree.nodes.length, greaterThan(1));

      final leafIndex2 = tree.appendLeaf(RatchetNode.blank());
      expect(leafIndex2.value, equals(2));
    });

    test('RatchetTree blankSubtree blanks node and ancestors', () {
      final tree = RatchetTree([
        RatchetNode.blank(), // 0
        RatchetNode.blank(), // 1
        RatchetNode.blank(), // 2
      ]);

      tree.blankSubtree(LeafIndex(0));
      expect(tree.nodes[1].isBlank, isTrue);
      expect(tree.nodes[0].isBlank, isTrue);
    });
  });
}

