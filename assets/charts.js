// assets/charts.js
(function() {
  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var accent3 = style.getPropertyValue('--accent3').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();

  // --- Chart: Architecture Flow ---
  var archChart = echarts.init(document.getElementById('chart-architecture'), null, { renderer: 'svg' });
  // We'll use a simple sankey-like representation
  archChart.setOption({
    tooltip: { trigger: 'item', appendToBody: true },
    animation: false,
    series: [{
      type: 'sankey',
      layout: 'none',
      emphasis: { focus: 'adjacency' },
      nodeAlign: 'left',
      nodeWidth: 18,
      nodeGap: 12,
      data: [
        { name: '外部HR系统', itemStyle: { color: accent } },
        { name: '预生成Pipeline', itemStyle: { color: accent2 } },
        { name: '能力标签库', itemStyle: { color: accent3 } },
        { name: '岗位基准库', itemStyle: { color: '#d97706' } },
        { name: '金标签库', itemStyle: { color: '#dc2626' } },
        { name: 'HR分析Agent', itemStyle: { color: accent } },
        { name: 'HR用户', itemStyle: { color: accent2 } }
      ],
      links: [
        { source: '外部HR系统', target: '预生成Pipeline', value: 1 },
        { source: '预生成Pipeline', target: '能力标签库', value: 1 },
        { source: '预生成Pipeline', target: '岗位基准库', value: 1 },
        { source: '预生成Pipeline', target: '金标签库', value: 1 },
        { source: '能力标签库', target: 'HR分析Agent', value: 1 },
        { source: '岗位基准库', target: 'HR分析Agent', value: 1 },
        { source: '金标签库', target: 'HR分析Agent', value: 1 },
        { source: 'HR分析Agent', target: 'HR用户', value: 1 }
      ]
    }]
  });
  window.addEventListener('resize', function() { archChart.resize(); });

  // --- Chart: Capability Radar ---
  var radarChart = echarts.init(document.getElementById('chart-radar'), null, { renderer: 'svg' });
  radarChart.setOption({
    tooltip: { appendToBody: true },
    animation: false,
    legend: {
      data: ['该员工', '同岗位平均', '金标签基准'],
      bottom: 0,
      textStyle: { color: muted, fontSize: 12 }
    },
    radar: {
      indicator: [
        { name: '项目管理能力', max: 10 },
        { name: '技术深度', max: 10 },
        { name: '业务理解力', max: 10 },
        { name: '跨部门协作', max: 10 },
        { name: '创新思维', max: 10 },
        { name: '数据驱动决策', max: 10 }
      ],
      shape: 'circle',
      name: { textStyle: { color: ink, fontSize: 11 } },
      splitArea: { areaStyle: { color: ['rgba(37,99,235,0.02)', 'rgba(37,99,235,0.05)'] } }
    },
    series: [{
      type: 'radar',
      data: [
        { value: [7, 8, 6, 5, 7, 6], name: '该员工', areaStyle: { color: 'rgba(37,99,235,0.2)' }, lineStyle: { color: accent }, itemStyle: { color: accent } },
        { value: [6, 6, 6, 6, 5, 6], name: '同岗位平均', lineStyle: { color: muted, type: 'dashed' }, itemStyle: { color: muted } },
        { value: [9, 9, 8, 8, 9, 8], name: '金标签基准', lineStyle: { color: '#dc2626', type: 'dashed' }, itemStyle: { color: '#dc2626' } }
      ]
    }]
  });
  window.addEventListener('resize', function() { radarChart.resize(); });

  // --- Chart: Tag Distribution ---
  var tagChart = echarts.init(document.getElementById('chart-tags'), null, { renderer: 'svg' });
  tagChart.setOption({
    tooltip: { trigger: 'axis', appendToBody: true },
    animation: false,
    legend: { data: ['通过评审', '未通过评审'], bottom: 0, textStyle: { color: muted, fontSize: 12 } },
    grid: { left: '3%', right: '8%', bottom: '20%', top: '5%', containLabel: true },
    xAxis: { type: 'category', data: ['项目管理', '技术深度', '业务理解', '协作能力', '创新能力', '数据分析'], axisLabel: { color: muted, fontSize: 11 }, axisLine: { lineStyle: { color: rule } } },
    yAxis: { type: 'value', name: '占比(%)', nameTextStyle: { color: muted, fontSize: 11 }, axisLabel: { color: muted }, splitLine: { lineStyle: { color: rule, type: 'dashed' } } },
    series: [
      { name: '通过评审', type: 'bar', data: [85, 78, 72, 68, 55, 80], itemStyle: { color: accent, borderRadius: [4,4,0,0] } },
      { name: '未通过评审', type: 'bar', data: [45, 35, 40, 50, 30, 42], itemStyle: { color: muted + '66', borderRadius: [4,4,0,0] } }
    ]
  });
  window.addEventListener('resize', function() { tagChart.resize(); });
})();