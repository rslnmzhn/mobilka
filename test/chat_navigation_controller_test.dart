import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/shell/presentation/chat_navigation_controller.dart';

void main() {
  test('exact narrow chat is the only context that can become visible', () {
    final controller = ChatNavigationController();
    addTearDown(controller.dispose);

    controller.updatePath('/models');
    controller.updateWidth(true);
    controller.show();
    expect(controller.visible, isFalse);
    controller.updatePath('/chat');
    controller.updateWidth(false);
    controller.show();
    expect(controller.visible, isFalse);
    controller.updateWidth(true);
    controller.show();
    expect(controller.visible, isTrue);
  });

  test('route, width, destination, and explicit hide reset visibility', () {
    final controller = ChatNavigationController();
    addTearDown(controller.dispose);
    controller.updatePath('/chat');
    controller.updateWidth(true);

    controller.show();
    controller.onDestination(0, 0);
    expect(controller.visible, isTrue);
    controller.onDestination(1, 0);
    expect(controller.visible, isFalse);

    controller.show();
    controller.updatePath('/models');
    expect(controller.visible, isFalse);
    controller.updatePath('/chat');
    controller.show();
    controller.updateWidth(false);
    expect(controller.visible, isFalse);

    controller.updateWidth(true);
    controller.show();
    controller.hide();
    expect(controller.visible, isFalse);
  });

  test('path and width context updates are independently idempotent', () {
    final controller = ChatNavigationController();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.updatePath('/chat');
    controller.updateWidth(true);
    controller.updatePath('/chat');
    controller.updateWidth(true);
    expect(notifications, 0);

    controller.show();
    expect(notifications, 1);
    controller.updatePath('/chat');
    controller.updateWidth(true);
    expect(controller.visible, isTrue);
    expect(notifications, 1);

    controller.updateWidth(false);
    expect(controller.visible, isFalse);
    expect(notifications, 2);
  });
}
