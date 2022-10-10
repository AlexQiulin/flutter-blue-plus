import 'package:bleinit/class/toast.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:wakelock/wakelock.dart';
import 'package:bleinit/class/public.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

void main() {
  // 设置android状态栏为透明的沉浸
  if (Platform.isAndroid) {
    SystemUiOverlayStyle systemUiOverlayStyle =
        const SystemUiOverlayStyle(statusBarColor: Colors.transparent);
    SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  }

  // 禁止应用横屏,强制竖屏
  WidgetsFlutterBinding.ensureInitialized(); //必须要添加这个进行初始化 否则下面会错误
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])
      .then((_) {
    runApp(GetMaterialApp(
      builder: BotToastInit(), //1.调用BotToastInit - Toast
      navigatorObservers: [BotToastNavigatorObserver()], //2.注册路由观察者 - Toast
      title: '蓝牙产品初始化', // APP后台运行名称
      debugShowCheckedModeBanner: false, // 右上角的DEBUG字样
      home: const MyApp(),
    ));
  });
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with SingleTickerProviderStateMixin {
  final List<String> tabs = const ['设备列表', '运行指令', '功能测试'];
  late TabController _tabController;
  late FlutterBluePlus ble; // 蓝牙实例化
  late BluetoothDevice bleDevice; // 蓝牙设备
  late BluetoothCharacteristic bleCharacteristic; // 蓝牙读写用的特征值
  late String bleToken; // 蓝牙TOKEN
  late String run1; // RUN1 运行指令
  late String run2; // RUN2 过警指令
  late String run3; // RUN3 扩展指令
  late String license; // 产品编号
  RxList<Widget> runLog = [const Text('')].obs;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin(); // 安卓设备信息
  bool isLocation = false;
  bool isConnected = false; // 蓝牙连接状态 默认未连接false
  bool noRunInit = false; // 只验证Token 不执行初始化
  @override
  void initState() {
    // TODO: implement initState
    super.initState();
    runLog.clear();
    _tabController = TabController(length: tabs.length, vsync: this);
    ble = FlutterBluePlus.instance; // 蓝牙构造函数
    Wakelock.enable(); // 屏幕保持常亮
    checkPermission(); // 检查权限
  }

  @override
  void dispose() {
    // TODO: implement dispose
    super.dispose();
    _tabController.dispose();
    runLog.clear();
  }

  // 检查权限
  checkPermission() async {
    AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
    if (androidInfo.version.sdkInt! < 31) {
      await Permission.location.request();
      isLocation = await Permission.location.isDenied;
      if (isLocation) {
        await Permission.location.request(); // 请求开启定位权限
        Toast().msg('定位未开启');
        return false;
      }
      return true;
    }
    return true;
  }

  // 扫描附近蓝牙设备
  scanBle() async {
    if (!await checkPermission()) {
      Toast().msg('定位未开启');
      return;
    }
    Toast().loading('正在扫描附近的蓝牙设备');
    ble.startScan(timeout: const Duration(seconds: 5)).then((value) {
      ble.stopScan();
      Toast().msg('本次搜索结束');
    });
  }

  // 监听连接状态
  bleStateListen() {
    bleDevice.state.listen((event) async {
      if (event == BluetoothDeviceState.connected) {
        Toast().loading('正在连接');
        isConnected = true;
        await Storage().set('MAC', bleDevice.id.toString());
        await bleDevice.discoverServices().then((value) async {
          List<BluetoothService> services = value
              .where((element) =>
                  element.uuid == Guid('0000FFA0-0000-1000-8000-00805f9b34fb'))
              .toList(); // 过滤主服务
          List<BluetoothCharacteristic> characteristics = services[0]
              .characteristics
              .where((element) =>
                  element.uuid == Guid('0000FFA1-0000-1000-8000-00805f9b34fb'))
              .toList(); // 过滤特征值
          bleCharacteristic = characteristics[0]; // 赋值
          md5Config();
          await notifyStatus(true);
        });
      }
      if (event == BluetoothDeviceState.disconnected) {
        isConnected = false;
        addLog('${bleDevice.name} 设备连接已断开');
        Toast().msg('已断开');
      }
    });
  }

  // MD5 加密
  md5Config() {
    List<int> md5License = const Utf8Encoder().convert('${bleDevice.id}');
    license = md5.convert(md5License).toString().toUpperCase();
    List<int> md5BleConfig = const Utf8Encoder().convert('${license}');
    bleToken = md5.convert(md5BleConfig).toString().toUpperCase();
    run1 = md5.convert(md5BleConfig).toString().toUpperCase();
    run2 = md5.convert(md5BleConfig).toString().toUpperCase();
    run3 = md5.convert(md5BleConfig).toString().toUpperCase();
  }

  // 运行配置
  runConfig() {
    if (!isConnected) {
      return Toast().msg('当前未连接任何设备');
    }
    write('TOKENSET=$bleToken'); // 步骤1：设置TOKEN
  }

  // 写数据
  write(String data, [bool noInit = false]) async {
    noRunInit = noInit;
    List<int> bytes = utf8.encode('$data\r\n'); // 转换成Utf8List发送，最后要添加回车
    bleCharacteristic.write(bytes);
  }

  // 开启Notify
  notifyStatus(bool status) async {
    await bleCharacteristic.setNotifyValue(status);
    // 监听Notify数据
    bleCharacteristic.value.listen((value) {
      List<int> bytes = value.map((e) => e).toList();
      String result = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll("\r\n", ""); // 去除了回车符号
      List<String> msg = result.split('|');
      print('Notify返回的数据：$msg', StackTrace.current);
      if (msg[0] == '') {
        Toast().msg('连接成功');
        runLog.clear();
        addLog('${bleDevice.name} 连接成功');
        addLog('模块License：$license');
        addLog('模块Token：$bleToken');
      } else {
        if (msg[0] == 'NOT TOKEN') {
          addLog('模块未初始化');
          Toast().msg('请先进行初始化');
          return;
        }
        notifyEvent({'key': msg[0], 'value': msg[1]});
      }
    });
  }

  // Notify处理
  notifyEvent(Map<String, String> map) async {
    switch (map['key']) {
      case 'TOKENS':
        if (map['value'] == 'ER') {
          Toast().msg('TOKEN已存在,请重置模块程序');
          addLog('TOKEN已存在,请重置模块程序');
        }
        if (map['value'] == 'OK') {
          addLog('TOKEN设置成功：$bleToken');
          write('TOKEN?=$bleToken'); // 步骤2：验证TOKEN
        }
        break;
    }
  }

  // 添加日志
  addLog(String data) {
    runLog.add(Text('${runLog.length + 1} $data'));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BluetoothState>(
        stream: ble.state,
        initialData: BluetoothState.unknown,
        builder: (c, snapshot) {
          final state = snapshot.data;
          if (state == BluetoothState.on) {
            return Scaffold(
              appBar: AppBar(
                title: const Text('初始化工具'),
                bottom: _buildTabBar(),
              ),
              body: _buildTabBarView(),
            );
          }
          return Scaffold(
            backgroundColor: Colors.red.shade900,
            body: bleOff(),
          );
        });
  }

  _buildTabBar() => PreferredSize(
        preferredSize: const Size.fromHeight(30),
        child: Theme(
          data: ThemeData(
            highlightColor: Colors.transparent, // 点击的背景高亮颜色
            splashColor: Colors.transparent, // 点击水波纹颜色
          ),
          child: TabBar(
            tabs: tabs.map((e) => Tab(text: e, height: 40)).toList(),
            controller: _tabController,
            labelStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            unselectedLabelStyle: const TextStyle(fontSize: 16),
          ),
        ),
      );

  Widget _buildTabBarView() =>
      TabBarView(controller: _tabController, children: [
        deviceList(),
        runOrder(),
        const Text('3'),
      ]);

  Widget deviceList() => Stack(
        children: [
          SingleChildScrollView(
              child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.instance.scanResults,
                  initialData: const [],
                  builder: (c, snapshot) {
                    if (snapshot.data!.isEmpty) {
                      return const SizedBox(
                        height: 500,
                        child: Center(
                          child: Text(
                            '暂无数据',
                            style:
                                TextStyle(fontSize: 20, color: Colors.black38),
                          ),
                        ),
                      );
                    }
                    return Column(
                      children: snapshot.data!.map((r) {
                        return bleScanItem(r);
                      }).toList(),
                    );
                  })),
          Positioned(
            bottom: 50,
            right: 50,
            child: FloatingActionButton(
              onPressed: () {
                isConnected ? Toast().msg('请先断开蓝牙连接后再搜索') : scanBle();
              },
              child: const Icon(
                Icons.bluetooth,
                size: 40,
              ),
            ),
          )
        ],
      );

  Widget bleScanItem(r) {
    if (r.device.name.isNotEmpty) {
      return Container(
          color: Colors.black12,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
              onTap: () {},
              leading: Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: const Color(0xff282828),
                  borderRadius: BorderRadius.circular((8)),
                ),
                child: const Center(
                  child: Icon(Icons.bluetooth, size: 32, color: Colors.white),
                ),
              ),
              title:
                  Text('名称：${r.device.name.isEmpty ? '无名设备' : r.device.name}'),
              subtitle: Text('Mac：${r.device.id}   ${r.rssi}'),
              trailing: StreamBuilder<BluetoothDeviceState>(
                  stream: r.device.state,
                  initialData: BluetoothDeviceState.disconnected,
                  builder: (c, snapshot) {
                    return ElevatedButton(
                      onPressed: () async {
                        if (!isConnected) {
                          bleDevice = r.device;
                          await bleDevice
                              .connect(autoConnect: false)
                              .then((value) {
                            bleStateListen(); // 监听蓝牙连接状态
                          });
                        } else {
                          await bleDevice.disconnect();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            snapshot.data == BluetoothDeviceState.connected
                                ? Colors.red.shade600
                                : const Color(0xff282828),
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                          snapshot.data == BluetoothDeviceState.connected
                              ? '断开'
                              : '连接'),
                    );
                  })));
    } else {
      return const SizedBox();
    }
  }

  Widget runOrder() => Stack(
        children: [
          SingleChildScrollView(
            child: Container(
              margin: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    height: 5,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton(
                        onPressed: () async {
                          if (isConnected) {
                            return Toast().msg('请先断开当前的设备连接');
                          }
                          String bleMac = await Storage().get(String, 'MAC');
                          if (bleMac == 'false') {
                            return Toast().msg('暂无Mac缓存,无法重连');
                          }
                          bleDevice =
                              BluetoothDevice.fromId(bleMac); // 根据缓存中的MAC地址连接蓝牙
                          await bleDevice
                              .connect(autoConnect: false)
                              .then((value) {
                            bleStateListen(); // 监听蓝牙连接状态
                          });

                          // if(!isConnected){
                          //   Toast().msg('当前未连接任何设备');
                          // }else{
                          //   write('TOKEN?=$bleToken',true); // 不执行初始化
                          //   Future.delayed(const Duration(milliseconds: 500),(){
                          //     write('PEIDUI=0',true); // 不执行初始化
                          //     addLog('执行了禁用配对');
                          //   });
                          // }
                        },
                        child: const Text('缓存重连'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          runLog.clear();
                        },
                        child: const Text('清除日志'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (!isConnected) {
                            Toast().msg('当前未连接任何设备');
                          } else {
                            write('INITBLE', true); // 不执行初始化
                          }
                        },
                        child: const Text('重置模块'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          if (!isConnected) {
                            Toast().msg('当前未连接任何设备');
                          } else {
                            await bleDevice.disconnect();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('断开连接'),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          if (!isConnected) {
                            Toast().msg('当前未连接任何设备');
                          } else {
                            write('TOKEN=$bleToken', true); // 不执行初始化
                          }
                        },
                        child: const Text('验证令牌'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (!isConnected) {
                            Toast().msg('当前未连接任何设备');
                          } else {
                            write('RSSI?', true); // 不执行初始化
                          }
                        },
                        child: const Text('信号探测'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (!isConnected) {
                            Toast().msg('当前未连接任何设备');
                          } else {
                            Toast().msg('该功能待定开发中');
                          }
                        },
                        child: const Text('功能未定'),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          await Storage().remove('MAC');
                          Toast().msg('MAC缓存已清理');
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade700,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('清除缓存'),
                      ),
                    ],
                  ),
                  Container(
                    margin: const EdgeInsets.only(top: 15),
                    child: const Text('执行日志',
                        style: TextStyle(fontSize: 18, color: Colors.black54)),
                  ),
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    padding: const EdgeInsets.only(top: 5),
                    child: Obx(() => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: runLog,
                        )),
                  )
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 50,
            right: 50,
            child: FloatingActionButton(
              onPressed: () {
                runConfig();
              },
              child: const Icon(
                Icons.share_location,
                size: 40,
              ),
            ),
          )
        ],
      );

  Widget bleOff() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.bluetooth_disabled,
              size: 200.0,
              color: Colors.white60,
            ),
            const SizedBox(height: 10),
            Text(
              '蓝牙未开启',
              style: Theme.of(context).primaryTextTheme.subtitle2?.copyWith(
                  color: Colors.white60,
                  fontSize: 26,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                await Permission.bluetoothConnect.request(); // 请求蓝牙权限
                ble.turnOn();
                Toast().loading();
                ble.state.listen((event) {
                  if (event == BluetoothState.on) {
                    Toast().close();
                    ble = FlutterBluePlus.instance;
                  }
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xff202020),
                foregroundColor: Colors.white,
              ),
              child: const Text('立即开启'),
            ),
          ],
        ),
      );
}
