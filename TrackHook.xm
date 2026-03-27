name: Build Tweak
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build:
    runs-on: macos-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - name: 安装 Theos
        run: |
          git clone --recursive https://github.com/theos/theos.git $THEOS
          echo "THEOS=$THEOS" >> $GITHUB_ENV
      
      - name: 安装依赖
        run: |
          brew install ldid
          brew install make
      
      - name: 编译
        run: |
          make clean
          make package
      
      - name: 上传成品
        uses: actions/upload-artifact@v4
        with:
          name: TrackHook
          path: packages/*.deb
