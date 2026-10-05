import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsEmail,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';

export class UpdateUserDto {
  @IsOptional()
  @IsEmail()
  @MaxLength(190)
  email?: string;
}

export class UpdateProfileDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(48)
  displayName?: string;

  @IsOptional()
  @IsString()
  @Matches(/^[a-z0-9_-]{1,32}$/, { message: 'avatarKey must be slug-like' })
  avatarKey?: string;

  @IsOptional()
  @IsString()
  @Matches(/^[A-Z]{2}$/, { message: 'countryCode must be an ISO-3166 alpha-2 code' })
  countryCode?: string;

  @IsOptional()
  @IsString()
  @MaxLength(280)
  bio?: string;

  @IsOptional()
  @Transform(({ value }) => value === true || value === 'true')
  @IsBoolean()
  isPublic?: boolean;
}
