#pragma once
#include "Newt/Session.h"
void StartAddonInputBridge();
void StopAddonInputBridge();
void SubmitAddonInput(const Newt::InputState& input);
