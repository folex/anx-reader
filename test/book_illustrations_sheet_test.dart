import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/widgets/ai/book_illustrations_sheet.dart';
void main(){
  testWidgets('illustration menu fits narrow screen with large text and exposes local actions', (tester) async{
    tester.view.physicalSize=const Size(320,700);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final operations=<Map<String,dynamic>>[];
    await tester.pumpWidget(MaterialApp(theme:ThemeData.dark(),home:MediaQuery(data:const MediaQueryData(size:Size(320,700),textScaler:TextScaler.linear(1.5)),child:Scaffold(body:BookIllustrationsSheet(
      onImported:(_){},handle:(input)async{operations.add(input);return {'images':[{'imageId':'id','index':0,'alt':'A drawing from the book','localEditing':true,'visible':true}]};},
    )))));
    await tester.pumpAndSettle();
    expect(find.text('Image generation'),findsOneWidget);
    expect(find.text('Import and insert image'),findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Image adjustments'));
    await tester.tap(find.byTooltip('Image adjustments'));await tester.pumpAndSettle();
    await tester.tap(find.text('Adapt drawing for dark mode'));await tester.pumpAndSettle();
    expect(operations.any((x)=>x['action']=='edit'&&x['target']=='dark'&&(x['filters'] as Map?)?['preset']=='dark-paper'),true);
    expect(tester.takeException(),isNull);
  });
}
