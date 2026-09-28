import { ImageResponse } from "next/og";

export const runtime = "edge";

export async function GET() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "1200px",
          height: "630px",
          display: "flex",
          background:
            "linear-gradient(135deg,#050816 0%,#0b1225 50%,#08101d 100%)",
          color: "white",
          padding: "42px",
          fontFamily: "Arial",
        }}
      >
        <div
          style={{
            display: "flex",
            width: "100%",
            flexDirection: "column",
            justifyContent: "space-between",
            border: "1px solid rgba(255,255,255,.12)",
            borderRadius: "28px",
            padding: "34px",
            background: "rgba(255,255,255,.035)",
          }}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
            }}
          >
            <div
              style={{
                display: "flex",
                flexDirection: "column",
              }}
            >
              <span
                style={{
                  fontSize: "24px",
                  color: "#86efac",
                  marginBottom: "12px",
                }}
              >
                HIGH QUALITY SIGNAL
              </span>

              <span
                style={{
                  fontSize: "64px",
                  fontWeight: 800,
                }}
              >
                $MSCOPE
              </span>

              <span
                style={{
                  fontSize: "26px",
                  color: "#cbd5e1",
                }}
              >
                MemeScope Test Signal
              </span>
            </div>

            <div
              style={{
                display: "flex",
                flexDirection: "column",
                alignItems: "flex-end",
              }}
            >
              <span
                style={{
                  fontSize: "22px",
                  color: "#94a3b8",
                }}
              >
                QUALITY SCORE
              </span>

              <span
                style={{
                  fontSize: "66px",
                  fontWeight: 800,
                  color: "#86efac",
                }}
              >
                87/100
              </span>
            </div>
          </div>

          <div
            style={{
              display: "flex",
              gap: "18px",
            }}
          >
            {[
              ["ENTRY", "$0.000124"],
              ["POTENTIAL TP", "+31.5%"],
              ["LIQUIDITY", "$92K"],
              ["MARKET CAP", "$410K"],
              ["BUY PRESSURE", "67%"],
              ["VOL SPIKE", "1.82x"],
            ].map(([label, value]) => (
              <div
                key={label}
                style={{
                  display: "flex",
                  flex: 1,
                  flexDirection: "column",
                  padding: "18px",
                  borderRadius: "18px",
                  background: "rgba(255,255,255,.05)",
                  border: "1px solid rgba(255,255,255,.08)",
                }}
              >
                <span
                  style={{
                    fontSize: "16px",
                    color: "#94a3b8",
                  }}
                >
                  {label}
                </span>

                <span
                  style={{
                    marginTop: "8px",
                    fontSize: "27px",
                    fontWeight: 700,
                  }}
                >
                  {value}
                </span>
              </div>
            ))}
          </div>

          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "flex-end",
            }}
          >
            <div
              style={{
                display: "flex",
                flexDirection: "column",
              }}
            >
              <span
                style={{
                  color: "#94a3b8",
                  fontSize: "18px",
                }}
              >
                CONTRACT
              </span>

              <span
                style={{
                  marginTop: "7px",
                  fontSize: "21px",
                }}
              >
                9xQeWv...V2wW3eN
              </span>
            </div>

            <div
              style={{
                display: "flex",
                fontSize: "22px",
                color: "#94a3b8",
              }}
            >
              MEMESCOPE • MAXSCALPLAB
            </div>
          </div>
        </div>
      </div>
    ),
    {
      width: 1200,
      height: 630,
    },
  );
}