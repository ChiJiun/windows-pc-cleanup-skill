// 側邊導覽用的線條圖示（inline SVG，跟著文字顏色）。
const common = {
  width: 18,
  height: 18,
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.8,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  "aria-hidden": true,
};

export const IconWizard = () => (
  <svg {...common}>
    <path d="M4 20l9-9" />
    <path d="M15 4l1 2 2 1-2 1-1 2-1-2-2-1 2-1z" />
    <path d="M19 12l.6 1.4L21 14l-1.4.6L19 16l-.6-1.4L17 14l1.4-.6z" />
  </svg>
);

export const IconChat = () => (
  <svg {...common}>
    <path d="M4 5h16v11H9l-5 4z" />
    <path d="M8 9h8M8 12h5" />
  </svg>
);

export const IconSettings = () => (
  <svg {...common}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8" />
  </svg>
);

export const IconInfo = () => (
  <svg {...common}>
    <circle cx="12" cy="12" r="9" />
    <path d="M12 11v5M12 8h.01" />
  </svg>
);

export const IconBroom = () => (
  <svg {...common} width={22} height={22}>
    <path d="M14 3l-4 9" />
    <path d="M6 13h8l2 8H4z" />
    <path d="M8 17v4M12 17v4" />
  </svg>
);
