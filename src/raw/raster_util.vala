using Singularity.Imaging;

namespace Singularity.Apps.Photos {

    namespace ExifOrientation {

        public FloatImage apply(FloatImage img, int orientation) {
            switch (orientation) {
                case 2: return img.flipped_horizontal();
                case 3: return img.rotated_quarter(2);
                case 4: return img.rotated_quarter(2).flipped_horizontal();
                case 5: return img.rotated_quarter(1).flipped_horizontal();
                case 6: return img.rotated_quarter(1);
                case 7: return img.rotated_quarter(3).flipped_horizontal();
                case 8: return img.rotated_quarter(3);
                default: return img;
            }
        }

        public bool swaps_axes(int orientation) {
            return orientation >= 5 && orientation <= 8;
        }
    }

    namespace HalfFloat {

        public float to_float(uint16 h) {
            uint32 sign = (uint32) (h >> 15) & 1;
            int exp = (h >> 10) & 0x1F;
            uint32 mant = h & 0x3FF;
            uint32 bits;
            if (exp == 0) {
                if (mant == 0) {
                    bits = sign << 31;
                } else {
                    int e = -1;
                    do {
                        e++;
                        mant <<= 1;
                    } while ((mant & 0x400) == 0);
                    mant &= 0x3FF;
                    bits = (sign << 31) | ((uint32) (127 - 15 - e) << 23) | (mant << 13);
                }
            } else if (exp == 31) {
                bits = (sign << 31) | 0x7F800000 | (mant << 13);
            } else {
                bits = (sign << 31) | ((uint32) (exp - 15 + 127) << 23) | (mant << 13);
            }
            return *((float*) (&bits));
        }

        public uint16 from_float(float f) {
            uint32 bits = *((uint32*) (&f));
            uint16 sign = (uint16) ((bits >> 16) & 0x8000);
            int exp = (int) ((bits >> 23) & 0xFF) - 127 + 15;
            uint32 mant = bits & 0x7FFFFF;
            if (exp <= 0) {
                if (exp < -10) return sign;
                mant = (mant | 0x800000) >> (1 - exp);
                return sign | (uint16) ((mant + 0x1000) >> 13);
            }
            if (exp >= 31) return sign | 0x7C00;
            return sign | (uint16) (exp << 10) | (uint16) ((mant + 0x1000) >> 13);
        }
    }
}
