import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Listenary',
  description: '以本地曲库为核心的 Windows 音乐播放器',
  base: '/',
  lang: 'zh-CN',
  head: [
    ['link', { rel: 'icon', href: '/logo.png' }],
    ['link', { rel: 'apple-touch-icon', href: '/logo.png' }],
    ['meta', { name: 'theme-color', content: '#BDA12F' }]
  ],
  appearance: true,
  themeConfig: {
    logo: '/logo.png',
    siteTitle: 'Listenary',
    nav: [
      { text: '首页', link: '/' },
      {
        text: '指南',
        items: [
          { text: '简介', link: '/guide/' },
          { text: '安装', link: '/guide/install' },
          { text: '快速上手', link: '/guide/quickstart' },
          { text: '常见问题', link: '/guide/faq' }
        ]
      },
      {
        text: '功能',
        items: [
          { text: '音乐库', link: '/guide/library' },
          { text: '播放与音频', link: '/guide/playback' },
          { text: '歌词', link: '/guide/lyrics' },
          { text: '桌面歌词', link: '/guide/desktop-lyric' },
          { text: '交互与手势', link: '/guide/interactions' },
          { text: '外观与设置', link: '/guide/settings' }
        ]
      },
      {
        text: '社区',
        items: [
          { text: '贡献指南', link: '/guide/contribute' },
          { text: '致谢', link: '/guide/credits' },
          { text: '待办规划', link: '/guide/todo' },
          { text: '更新日志', link: '/guide/changelog' }
        ]
      },
      {
        text: '开发',
        items: [
          { text: '架构', link: '/dev/' },
          { text: '构建', link: '/dev/build' }
        ]
      },
      { text: '下载', link: '/download' }
    ],
    sidebar: {
      '/guide/': [
        {
          text: '开始',
          items: [
            { text: '简介', link: '/guide/' },
            { text: '安装', link: '/guide/install' },
            { text: '快速上手', link: '/guide/quickstart' }
          ]
        },
        {
          text: '功能',
          items: [
            { text: '音乐库', link: '/guide/library' },
            { text: '播放与音频', link: '/guide/playback' },
            { text: '歌词', link: '/guide/lyrics' },
            { text: '桌面歌词', link: '/guide/desktop-lyric' },
            { text: '交互与手势', link: '/guide/interactions' },
            { text: '外观与设置', link: '/guide/settings' }
          ]
        },
        {
          text: '社区',
          items: [
            { text: '贡献指南', link: '/guide/contribute' },
            { text: '致谢', link: '/guide/credits' },
            { text: '待办规划', link: '/guide/todo' },
            { text: '更新日志', link: '/guide/changelog' }
          ]
        },
        {
          text: '帮助',
          items: [
            { text: '常见问题', link: '/guide/faq' },
            { text: '快捷键', link: '/guide/hotkeys' }
          ]
        }
      ],
      '/dev/': [
        {
          text: '开发',
          items: [
            { text: '架构', link: '/dev/' },
            { text: '构建', link: '/dev/build' }
          ]
        }
      ]
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/HuiZhou12/Listenary' }
    ],
    footer: {
      message: '以 GPL-3.0 许可发布。',
      copyright: 'Copyright © 2026 HuiZhou12'
    },
    outline: {
      label: '本页目录',
      level: [2, 3]
    },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: {
            buttonText: '搜索',
            buttonAriaLabel: '搜索文档'
          },
          modal: {
            displayDetails: '显示详细列表',
            resetButtonTitle: '清除搜索',
            backButtonTitle: '关闭搜索',
            noResultsText: '没有找到结果',
            footer: {
              selectText: '选择',
              selectKeyAriaLabel: '回车',
              navigateText: '切换',
              navigateUpKeyAriaLabel: '上箭头',
              navigateDownKeyAriaLabel: '下箭头',
              closeText: '关闭',
              closeKeyAriaLabel: 'Esc'
            }
          }
        }
      }
    },
    notFound: {
      code: '404',
      title: '页面不存在',
      quote: '链接可能写错了，或页面已经搬走。回首页再找找吧。',
      linkLabel: '返回首页',
      linkText: '返回首页'
    },
    darkModeSwitchLabel: '外观',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    langMenuLabel: '切换语言',
    skipToContentLabel: '跳到正文',
    docFooter: {
      prev: '上一页',
      next: '下一页'
    }
  }
})
