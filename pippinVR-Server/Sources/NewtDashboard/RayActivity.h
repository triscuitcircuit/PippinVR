#ifndef NEWT_RAYACTIVITY_H
#define NEWT_RAYACTIVITY_H

#include <algorithm>
#include <array>
#include <cmath>



class RayActivity {
public:
    double idleSeconds = 2.0;
    double wakeDistanceMeters = 0.02;
    double wakeAngleDegrees = 3.0;

    void Update(double now, bool tracked, const std::array<float, 3>& position,
                const std::array<float, 4>& orientation, bool interacting) {
        if (!tracked) { valid = false; return; }
        double distanceSquared = 0;
        double dot = 0, norm = 0, anchorNorm = 0;
        for (int i = 0; i < 3; ++i) {
            const double delta = position[i] - anchorPosition[i];
            distanceSquared += delta * delta;
        }
        for (int i = 0; i < 4; ++i) {
            dot += orientation[i] * anchorOrientation[i];
            norm += orientation[i] * orientation[i];
            anchorNorm += anchorOrientation[i] * anchorOrientation[i];
        }
        if (!std::isfinite(distanceSquared) || !std::isfinite(norm) || norm < 1e-8) { valid = false; return; }
        dot /= std::sqrt(norm * anchorNorm);
        const bool inputStarted = interacting && !inputWasActive;
        inputWasActive = interacting;

        const double rotationLimit = std::cos(wakeAngleDegrees * 3.141592653589793 / 360.0);
        if (!valid || inputStarted || distanceSquared >= wakeDistanceMeters * wakeDistanceMeters ||
            std::min(1.0, std::abs(dot)) < rotationLimit) {
            lastActivity = now;
            anchorPosition = position;
            anchorOrientation = orientation;
        }
        valid = true;
    }

    float Alpha(double now) const {
        if (!valid) return 0;
        if (idleSeconds == 0) return 1;
        return static_cast<float>(std::clamp(1.0 - (now - lastActivity - idleSeconds) / 0.2, 0.0, 1.0));
    }

private:
    bool valid = false;
    bool inputWasActive = false;
    double lastActivity = 0;
    std::array<float, 3> anchorPosition{};
    std::array<float, 4> anchorOrientation{0, 0, 0, 1};
};

#endif
